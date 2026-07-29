"""Claude Code hook adapter.

Claude's PermissionRequest HTTP hook remains open while Headroom presents the
request elsewhere. A phone response wakes that exact handler, which returns
Claude's documented allow/deny JSON. Passive lifecycle hooks use the same
ledger but never pretend they can answer a question they did not receive.
"""

from __future__ import annotations

import json
import os
import threading
import time
import uuid

import agent_events
import claude_hooks

PROVIDER = "claude-code"
ADAPTER = "claude-http-hooks"
DEFAULT_WAIT_SECONDS = 285
MAX_WAIT_SECONDS = 600

PERMISSION_ACTIONS = [
    {
        "id": "approve_once",
        "label": "Allow once",
        "risk": "privileged",
        "requires_foreground": True,
        "requires_biometric": True,
    },
    {"id": "decline", "label": "Deny", "risk": "safe"},
]

PASSIVE_ACTIONS = [
    {"id": "dismiss", "label": "Dismiss", "risk": "safe"},
]


def _short(value, fallback, limit=240):
    text = str(value or "").strip() or fallback
    return text if len(text) <= limit else text[:limit - 1] + "…"


def _project(cwd):
    value = str(cwd or "").rstrip("/")
    return os.path.basename(value) or "Claude Code"


def _command_summary(tool_name, tool_input):
    if isinstance(tool_input, dict):
        for key in ("command", "description", "file_path", "path", "query"):
            value = tool_input.get(key)
            if isinstance(value, str) and value.strip():
                return _short(value, f"Use {tool_name}")
    return f"Use {tool_name}"


class _PendingPermission:
    def __init__(self):
        self.ready = threading.Event()
        self.action = None


class ClaudeCodeHooks:
    def __init__(self, store):
        self.store = store
        self._lock = threading.Lock()
        self._pending = {}

    def capabilities(self):
        try:
            hook_status = claude_hooks.inspect()
            enabled = bool(hook_status["installed_events"])
            connection = "ready" if enabled else "disabled"
            error = None
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            enabled = False
            connection = "disconnected"
            error = str(exc)
        return {
            "provider": PROVIDER,
            "adapter": ADAPTER,
            "session_ownership": "external_hook",
            "enabled": enabled,
            "available": True,
            "connection": connection,
            "error": error,
            "version": None,
            "capabilities": {
                "command_approval": {
                    "supported": True, "maturity": "stable"},
                "file_approval": {
                    "supported": True, "maturity": "stable"},
                "permission_grant": {
                    "supported": False, "maturity": "planned"},
                "structured_question": {
                    "supported": False, "maturity": "notify_only"},
                "send_message": {
                    "supported": False, "maturity": "planned"},
                "interrupt": {
                    "supported": False, "maturity": "planned"},
            },
        }

    def stop(self):
        with self._lock:
            pending = list(self._pending.items())
            self._pending.clear()
        for event_id, waiter in pending:
            self.store.mark_orphaned(event_id, "Headroom host stopped")
            waiter.ready.set()

    def permission_request(self, payload, wait_seconds=DEFAULT_WAIT_SECONDS):
        """Create an event and wait for its exact allow/deny response.

        Returning None means "no hook decision": Claude falls back to its
        ordinary local permission dialog.
        """
        session_id = payload.get("session_id")
        tool_name = payload.get("tool_name")
        tool_input = payload.get("tool_input")
        if not isinstance(session_id, str) or not session_id.strip():
            raise agent_events.InvalidEvent("Claude session_id is required")
        if not isinstance(tool_name, str) or not tool_name.strip():
            raise agent_events.InvalidEvent("Claude tool_name is required")
        if not isinstance(tool_input, dict):
            raise agent_events.InvalidEvent("Claude tool_input must be an object")
        wait_seconds = max(1, min(MAX_WAIT_SECONDS, int(wait_seconds)))
        provider_request_id = "permission-" + uuid.uuid4().hex
        cwd = payload.get("cwd")
        with self._lock:
            event = self.store.create(
                provider=PROVIDER,
                adapter=ADAPTER,
                provider_request_id=provider_request_id,
                session_id=session_id,
                kind="permission_approval",
                title=f"Claude needs permission in {_project(cwd)}",
                summary=_command_summary(tool_name, tool_input),
                actions=PERMISSION_ACTIONS,
                detail={
                    "tool_name": tool_name,
                    "tool_input": tool_input,
                    "cwd": cwd,
                    "transcript_path": payload.get("transcript_path"),
                    "permission_mode": payload.get("permission_mode"),
                    "permission_suggestions": payload.get(
                        "permission_suggestions") or [],
                },
                expires_at_ms=int((time.time() + wait_seconds) * 1000),
            )
            waiter = _PendingPermission()
            self._pending[event["id"]] = waiter
        waiter.ready.wait(wait_seconds)
        with self._lock:
            self._pending.pop(event["id"], None)
        if waiter.action is None:
            self.store.expire(event["id"], "Claude permission hook timed out")
            return None
        if waiter.action == "approve_once":
            self.store.resolve(event["id"], {"action": waiter.action})
            return {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {"behavior": "allow"},
                },
            }
        return {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {
                    "behavior": "deny",
                    "message": "Denied from Headroom",
                },
            },
        }

    def lifecycle_event(self, payload):
        session_id = payload.get("session_id")
        hook = payload.get("hook_event_name")
        if not isinstance(session_id, str) or not session_id.strip():
            raise agent_events.InvalidEvent("Claude session_id is required")
        if not isinstance(hook, str) or not hook.strip():
            raise agent_events.InvalidEvent(
                "Claude hook_event_name is required")
        if hook in ("UserPromptSubmit", "SessionEnd"):
            self.store.resolve_session(
                PROVIDER, ADAPTER, session_id,
                {"reason": hook},
            )
            return None
        if hook == "Stop":
            tasks = payload.get("background_tasks")
            if isinstance(tasks, list) and any(
                    isinstance(task, dict)
                    and str(task.get("status", "")).lower()
                    not in ("completed", "failed", "cancelled")
                    for task in tasks):
                return None
            return self._passive(
                payload, "agent_waiting",
                "Claude finished responding",
                "Ready for your next instruction",
            )
        if hook != "Notification":
            return None
        notification_type = str(payload.get("notification_type") or "")
        # PermissionRequest carries the actual command and response channel.
        if notification_type == "permission_prompt":
            return None
        if notification_type == "idle_prompt":
            title = "Claude is waiting for you"
            kind = "agent_waiting"
        elif notification_type == "elicitation_dialog":
            title = "Claude needs input"
            kind = "structured_question"
        else:
            return None
        return self._passive(
            payload, kind, title,
            _short(payload.get("message"), "Open Claude Code to continue"),
        )

    def _passive(self, payload, kind, title, summary):
        return self.store.create(
            provider=PROVIDER,
            adapter=ADAPTER,
            provider_request_id="notice-" + uuid.uuid4().hex,
            session_id=payload["session_id"],
            kind=kind,
            title=f"{title} in {_project(payload.get('cwd'))}",
            summary=summary,
            actions=PASSIVE_ACTIONS,
            detail={
                "cwd": payload.get("cwd"),
                "transcript_path": payload.get("transcript_path"),
                "notification_type": payload.get("notification_type"),
                "message": payload.get("message"),
            },
        )

    def respond(self, event, action_id):
        if action_id == "dismiss":
            self.store.resolve(event["id"], {"action": action_id})
            return
        if action_id not in ("approve_once", "decline"):
            raise ValueError("unsupported Claude action")
        with self._lock:
            waiter = self._pending.get(event["id"])
            if waiter is None:
                raise RuntimeError("Claude request is no longer pending")
            waiter.action = action_id
            waiter.ready.set()
