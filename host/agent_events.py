"""Persistent, provider-neutral coding-agent attention events.

The live provider callback stays in its adapter process; this ledger owns the
durable user-facing state. SQLite is intentionally the only dependency. Every
transition is compare-and-swap guarded so two phones, a stale notification,
and a provider-side resolution cannot answer the same question twice.
"""

from __future__ import annotations

import json
import os
import sqlite3
import threading
import time
import uuid

STORE_PATH = os.path.expanduser("~/.headroom/attention.sqlite3")
OPEN_STATES = ("pending", "responding")
TERMINAL_STATES = ("resolved", "declined", "cancelled", "expired", "orphaned")
ALL_STATES = OPEN_STATES + TERMINAL_STATES
MAX_TEXT = 4096
# Adapters bound their own request fields (see agent_request); this is the
# backstop that keeps one pathological tool input out of the ledger, the HTTP
# response and every client that polls them.
MAX_DETAIL = 64 * 1024


class EventError(Exception):
    """Base class for safe HTTP-facing event errors."""


class EventNotFound(EventError):
    pass


class EventConflict(EventError):
    pass


class InvalidEvent(EventError):
    pass


def _now_ms():
    return int(time.time() * 1000)


def _json(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=True)


def _load(value, fallback):
    try:
        result = json.loads(value)
    except (TypeError, json.JSONDecodeError):
        return fallback
    return result


def _text(value, field, allow_empty=False):
    if value is None:
        return None
    if not isinstance(value, str):
        raise InvalidEvent(f"{field} must be a string")
    value = value.strip()
    if not value and not allow_empty:
        raise InvalidEvent(f"{field} is required")
    if len(value) > MAX_TEXT:
        raise InvalidEvent(f"{field} is too long")
    return value


def _actions(value):
    if not isinstance(value, list) or not value:
        raise InvalidEvent("actions are required")
    result = []
    seen = set()
    for raw in value:
        if not isinstance(raw, dict):
            raise InvalidEvent("each action must be an object")
        action_id = _text(raw.get("id"), "action id")
        label = _text(raw.get("label"), "action label")
        if action_id in seen:
            raise InvalidEvent(f"duplicate action {action_id}")
        seen.add(action_id)
        risk = str(raw.get("risk") or "safe")
        if risk not in ("safe", "privileged", "destructive"):
            raise InvalidEvent(f"unknown action risk {risk}")
        action = {
            "id": action_id,
            "label": label,
            "risk": risk,
            "requires_foreground": bool(raw.get("requires_foreground")),
            "requires_biometric": bool(raw.get("requires_biometric")),
        }
        # Why you would pick this one. An answer that carries its own reason
        # is one control instead of a list beside a row of buttons saying the
        # same words.
        description = raw.get("description")
        if isinstance(description, str) and description.strip():
            action["description"] = _text(description, "action description")
        # Answers that carry typed words rather than just a decision. The
        # client shows a field; the adapter decides what the words mean.
        if raw.get("accepts_text"):
            action["accepts_text"] = True
        result.append(action)
    return result


class EventStore:
    """Thread-safe SQLite ledger with one connection per operation."""

    def __init__(self, path=STORE_PATH):
        self.path = path
        self._init_lock = threading.Lock()
        self._initialized = False

    def _connect(self):
        self._ensure_schema()
        connection = sqlite3.connect(
            self.path, timeout=5, isolation_level=None)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        return connection

    def _ensure_schema(self):
        if self._initialized:
            return
        with self._init_lock:
            if self._initialized:
                return
            folder = os.path.dirname(self.path)
            if folder:
                os.makedirs(folder, mode=0o700, exist_ok=True)
            connection = sqlite3.connect(self.path, timeout=5)
            try:
                connection.executescript("""
                    PRAGMA journal_mode = WAL;
                    PRAGMA foreign_keys = ON;
                    CREATE TABLE IF NOT EXISTS attention_events (
                        id TEXT PRIMARY KEY,
                        provider TEXT NOT NULL,
                        adapter TEXT NOT NULL,
                        provider_request_id TEXT NOT NULL,
                        session_id TEXT NOT NULL,
                        turn_id TEXT,
                        item_id TEXT,
                        kind TEXT NOT NULL,
                        state TEXT NOT NULL,
                        revision INTEGER NOT NULL,
                        title TEXT NOT NULL,
                        summary TEXT NOT NULL,
                        detail_json TEXT NOT NULL,
                        actions_json TEXT NOT NULL,
                        created_at_ms INTEGER NOT NULL,
                        updated_at_ms INTEGER NOT NULL,
                        expires_at_ms INTEGER,
                        resolution_json TEXT,
                        UNIQUE(provider, adapter, provider_request_id)
                    );
                    CREATE INDEX IF NOT EXISTS attention_events_state_updated
                    ON attention_events(state, updated_at_ms, id);
                    CREATE INDEX IF NOT EXISTS attention_events_turn
                    ON attention_events(provider, adapter, turn_id);
                    CREATE TABLE IF NOT EXISTS attention_responses (
                        event_id TEXT NOT NULL,
                        idempotency_key TEXT NOT NULL,
                        action_id TEXT NOT NULL,
                        state TEXT NOT NULL,
                        created_at_ms INTEGER NOT NULL,
                        updated_at_ms INTEGER NOT NULL,
                        error TEXT,
                        PRIMARY KEY(event_id, idempotency_key),
                        FOREIGN KEY(event_id) REFERENCES attention_events(id)
                            ON DELETE CASCADE
                    );
                """)
                connection.commit()
            finally:
                connection.close()
            try:
                os.chmod(self.path, 0o600)
            except OSError:
                pass
            self._initialized = True

    @staticmethod
    def _public(row):
        if row is None:
            return None
        return {
            "id": row["id"],
            "provider": row["provider"],
            "adapter": row["adapter"],
            "session_id": row["session_id"],
            "turn_id": row["turn_id"],
            "item_id": row["item_id"],
            "kind": row["kind"],
            "state": row["state"],
            "revision": row["revision"],
            "title": row["title"],
            "summary": row["summary"],
            "detail": _load(row["detail_json"], {}),
            "actions": _load(row["actions_json"], []),
            "created_at_ms": row["created_at_ms"],
            "updated_at_ms": row["updated_at_ms"],
            "expires_at_ms": row["expires_at_ms"],
            "resolution": _load(row["resolution_json"], None),
        }

    def create(
        self, *, provider, adapter, provider_request_id, session_id, kind,
        title, summary, actions, turn_id=None, item_id=None, detail=None,
        created_at_ms=None, expires_at_ms=None,
    ):
        provider = _text(provider, "provider")
        adapter = _text(adapter, "adapter")
        provider_request_id = _text(
            provider_request_id, "provider request id")
        session_id = _text(session_id, "session id")
        turn_id = _text(turn_id, "turn id") if turn_id is not None else None
        item_id = _text(item_id, "item id") if item_id is not None else None
        kind = _text(kind, "kind")
        title = _text(title, "title")
        summary = _text(summary, "summary")
        actions = _actions(actions)
        if detail is not None and not isinstance(detail, dict):
            raise InvalidEvent("detail must be an object")
        detail_json = _json(detail or {})
        if len(detail_json) > MAX_DETAIL:
            raise InvalidEvent("detail is too large")
        created_at_ms = int(created_at_ms or _now_ms())
        expires_at_ms = (
            int(expires_at_ms) if expires_at_ms is not None else None)
        event_id = "evt_" + uuid.uuid4().hex
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            existing = connection.execute(
                """SELECT * FROM attention_events
                   WHERE provider = ? AND adapter = ?
                     AND provider_request_id = ?""",
                (provider, adapter, provider_request_id),
            ).fetchone()
            if existing is not None:
                connection.commit()
                return self._public(existing)
            connection.execute(
                """INSERT INTO attention_events (
                       id, provider, adapter, provider_request_id, session_id,
                       turn_id, item_id, kind, state, revision, title, summary,
                       detail_json, actions_json, created_at_ms, updated_at_ms,
                       expires_at_ms
                   ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', 1, ?, ?, ?,
                             ?, ?, ?, ?)""",
                (
                    event_id, provider, adapter, provider_request_id, session_id,
                    turn_id, item_id, kind, title, summary,
                    detail_json, _json(actions), created_at_ms,
                    created_at_ms, expires_at_ms,
                ),
            )
            row = connection.execute(
                "SELECT * FROM attention_events WHERE id = ?", (event_id,)
            ).fetchone()
            connection.commit()
            return self._public(row)
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def get(self, event_id):
        connection = self._connect()
        try:
            row = connection.execute(
                "SELECT * FROM attention_events WHERE id = ?", (event_id,)
            ).fetchone()
            if row is None:
                raise EventNotFound("attention event not found")
            return self._public(row)
        finally:
            connection.close()

    def list(self, state="open", limit=50, after_ms=None):
        limit = max(1, min(100, int(limit)))
        args = []
        where = []
        if state == "open":
            where.append("state IN ('pending', 'responding')")
        elif state != "all":
            if state not in ALL_STATES:
                raise InvalidEvent("unknown event state")
            where.append("state = ?")
            args.append(state)
        if after_ms is not None:
            where.append("updated_at_ms > ?")
            args.append(int(after_ms))
        query = "SELECT * FROM attention_events"
        if where:
            query += " WHERE " + " AND ".join(where)
        query += " ORDER BY updated_at_ms DESC, id DESC LIMIT ?"
        args.append(limit)
        connection = self._connect()
        try:
            return [
                self._public(row)
                for row in connection.execute(query, args).fetchall()
            ]
        finally:
            connection.close()

    def claim(self, event_id, revision, action_id, idempotency_key):
        event_id = _text(event_id, "event id")
        action_id = _text(action_id, "action")
        idempotency_key = _text(idempotency_key, "idempotency key")
        try:
            revision = int(revision)
        except (TypeError, ValueError):
            raise InvalidEvent("revision must be an integer")
        now = _now_ms()
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT * FROM attention_events WHERE id = ?", (event_id,)
            ).fetchone()
            if row is None:
                raise EventNotFound("attention event not found")
            duplicate = connection.execute(
                """SELECT state, action_id FROM attention_responses
                   WHERE event_id = ? AND idempotency_key = ?""",
                (event_id, idempotency_key),
            ).fetchone()
            if duplicate is not None:
                if duplicate["action_id"] != action_id:
                    raise EventConflict(
                        "idempotency key was already used for another action")
                connection.commit()
                return self._public(row), True
            if row["state"] != "pending":
                raise EventConflict(f"event is already {row['state']}")
            if row["revision"] != revision:
                raise EventConflict("event changed; refresh first")
            actions = {
                action.get("id")
                for action in _load(row["actions_json"], [])
                if isinstance(action, dict)
            }
            if action_id not in actions:
                raise InvalidEvent("action is not available")
            if row["expires_at_ms"] is not None and row["expires_at_ms"] <= now:
                connection.execute(
                    """UPDATE attention_events
                       SET state = 'expired', revision = revision + 1,
                           updated_at_ms = ?
                       WHERE id = ?""",
                    (now, event_id),
                )
                connection.commit()
                raise EventConflict("event expired")
            connection.execute(
                """INSERT INTO attention_responses (
                       event_id, idempotency_key, action_id, state,
                       created_at_ms, updated_at_ms
                   ) VALUES (?, ?, ?, 'dispatching', ?, ?)""",
                (event_id, idempotency_key, action_id, now, now),
            )
            connection.execute(
                """UPDATE attention_events
                   SET state = 'responding', revision = revision + 1,
                       updated_at_ms = ?
                   WHERE id = ?""",
                (now, event_id),
            )
            claimed = connection.execute(
                "SELECT * FROM attention_events WHERE id = ?", (event_id,)
            ).fetchone()
            connection.commit()
            return self._public(claimed), False
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def mark_dispatched(self, event_id, idempotency_key):
        now = _now_ms()
        connection = self._connect()
        try:
            response = connection.execute(
                """SELECT action_id FROM attention_responses
                   WHERE event_id = ? AND idempotency_key = ?""",
                (event_id, idempotency_key),
            ).fetchone()
            connection.execute(
                """UPDATE attention_responses
                   SET state = 'dispatched', updated_at_ms = ?
                   WHERE event_id = ? AND idempotency_key = ?""",
                (now, event_id, idempotency_key),
            )
            terminal = {
                "decline": "declined",
                "cancel": "cancelled",
            }.get(response["action_id"] if response is not None else None)
            if terminal is not None:
                connection.execute(
                    """UPDATE attention_events
                       SET state = ?, revision = revision + 1,
                           updated_at_ms = ?, resolution_json = ?
                       WHERE id = ? AND state = 'responding'""",
                    (
                        terminal, now,
                        _json({"action": response["action_id"]}), event_id,
                    ),
                )
        finally:
            connection.close()

    def mark_orphaned(self, event_id, error=None):
        now = _now_ms()
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(
                """UPDATE attention_events
                   SET state = 'orphaned', revision = revision + 1,
                       updated_at_ms = ?, resolution_json = ?
                   WHERE id = ? AND state IN ('pending', 'responding')""",
                (now, _json({"error": str(error or "adapter disconnected")}),
                 event_id),
            )
            connection.execute(
                """UPDATE attention_responses
                   SET state = 'failed', updated_at_ms = ?, error = ?
                   WHERE event_id = ? AND state = 'dispatching'""",
                (now, str(error or "adapter disconnected"), event_id),
            )
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def resolve(self, event_id, resolution=None):
        now = _now_ms()
        connection = self._connect()
        try:
            connection.execute(
                """UPDATE attention_events
                   SET state = 'resolved', revision = revision + 1,
                       updated_at_ms = ?, resolution_json = ?
                   WHERE id = ? AND state IN ('pending', 'responding')""",
                (now, _json(resolution or {}), event_id),
            )
        finally:
            connection.close()

    def resolve_turn(self, provider, adapter, turn_id, resolution=None):
        now = _now_ms()
        connection = self._connect()
        try:
            connection.execute(
                """UPDATE attention_events
                   SET state = 'resolved', revision = revision + 1,
                       updated_at_ms = ?, resolution_json = ?
                   WHERE provider = ? AND adapter = ? AND turn_id = ?
                     AND state IN ('pending', 'responding')""",
                (
                    now, _json(resolution or {}), provider, adapter, turn_id,
                ),
            )
        finally:
            connection.close()

    def supersede(self, provider, adapter, session_id, kind, resolution=None):
        """Retire this session's earlier notice of the same kind.

        A passive notice describes a state, not an event: "Claude finished" is
        true of a session, and a second copy says nothing the first did not.
        Without this they stack until dismissed and bury the rows that
        actually want an answer.

        Scoped by kind on purpose — a pending approval for the same session is
        a different thing and must never be closed by a notice arriving.
        """
        now = _now_ms()
        connection = self._connect()
        try:
            connection.execute(
                """UPDATE attention_events
                   SET state = 'resolved', revision = revision + 1,
                       updated_at_ms = ?, resolution_json = ?
                   WHERE provider = ? AND adapter = ? AND session_id = ?
                     AND kind = ? AND state IN ('pending', 'responding')""",
                (
                    now, _json(resolution or {"reason": "superseded"}),
                    provider, adapter, session_id, kind,
                ),
            )
        finally:
            connection.close()

    def resolve_session(self, provider, adapter, session_id, resolution=None):
        """Close passive attention rows when a provider session moves again."""
        now = _now_ms()
        connection = self._connect()
        try:
            connection.execute(
                """UPDATE attention_events
                   SET state = 'resolved', revision = revision + 1,
                       updated_at_ms = ?, resolution_json = ?
                   WHERE provider = ? AND adapter = ? AND session_id = ?
                     AND state IN ('pending', 'responding')""",
                (
                    now, _json(resolution or {}), provider, adapter, session_id,
                ),
            )
        finally:
            connection.close()

    def expire(self, event_id, reason="provider request timed out"):
        """Expire one still-open callback without overwriting a phone answer."""
        now = _now_ms()
        connection = self._connect()
        try:
            connection.execute(
                """UPDATE attention_events
                   SET state = 'expired', revision = revision + 1,
                       updated_at_ms = ?, resolution_json = ?
                   WHERE id = ? AND state = 'pending'""",
                (now, _json({"reason": str(reason)}), event_id),
            )
        finally:
            connection.close()

    def orphan_adapter(self, provider, adapter, error=None):
        now = _now_ms()
        connection = self._connect()
        try:
            connection.execute(
                """UPDATE attention_events
                   SET state = 'orphaned', revision = revision + 1,
                       updated_at_ms = ?, resolution_json = ?
                   WHERE provider = ? AND adapter = ?
                     AND state IN ('pending', 'responding')""",
                (
                    now, _json({"error": str(error or "adapter disconnected")}),
                    provider, adapter,
                ),
            )
        finally:
            connection.close()
