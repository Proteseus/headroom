"""Provider-neutral facade used by Headroom's HTTP server."""

from __future__ import annotations

import threading

import agent_events
import app_config
import claude_code
import codex_app_server

_lock = threading.Lock()
_instance = None


class AgentGateway:
    def __init__(self, store=None, codex=None, claude=None):
        self._adapter_lock = threading.Lock()
        self.store = store or agent_events.EventStore()
        self.codex = codex or codex_app_server.CodexAppServer(self.store)
        self.claude = claude or claude_code.ClaudeCodeHooks(self.store)
        self.adapters = {
            codex_app_server.PROVIDER: self.codex,
            claude_code.PROVIDER: self.claude,
        }

    def start(self):
        with self._adapter_lock:
            codex = self.codex
        codex.start()

    def stop(self):
        with self._adapter_lock:
            codex = self.codex
            claude = self.claude
        codex.stop()
        claude.stop()

    def capabilities(self):
        with self._adapter_lock:
            codex = self.codex
            claude = self.claude
        return {
            "ok": True,
            "providers": [codex.capabilities(), claude.capabilities()],
        }

    def configuration(self):
        with self._adapter_lock:
            provider = self.codex.capabilities()
        return {
            "ok": True,
            "enabled": app_config.agent_gateway_enabled(),
            "codex_binary": app_config.codex_binary(),
            "provider": provider,
        }

    def reconfigure(self):
        """Replace the adapter after config changes, orphaning live callbacks."""
        with self._adapter_lock:
            previous = self.codex
        previous.stop()
        replacement = codex_app_server.CodexAppServer(self.store)
        with self._adapter_lock:
            self.codex = replacement
            self.adapters[codex_app_server.PROVIDER] = replacement
        replacement.start()
        return self.configuration()

    def codex_start_task(self, cwd, prompt):
        with self._adapter_lock:
            codex = self.codex
        return {"ok": True, "task": codex.start_task(cwd, prompt)}

    def codex_steer(self, text):
        with self._adapter_lock:
            codex = self.codex
        return {"ok": True, "task": codex.steer(text)}

    def codex_task(self):
        with self._adapter_lock:
            codex = self.codex
        return {"ok": True, "task": codex.active_task()}

    def claude_permission(self, payload, wait_seconds=None):
        with self._adapter_lock:
            claude = self.claude
        if wait_seconds is None:
            return claude.permission_request(payload)
        return claude.permission_request(payload, wait_seconds=wait_seconds)

    def claude_question(self, payload, wait_seconds=None):
        with self._adapter_lock:
            claude = self.claude
        if wait_seconds is None:
            return claude.question_request(payload)
        return claude.question_request(payload, wait_seconds=wait_seconds)

    def claude_event(self, payload):
        with self._adapter_lock:
            claude = self.claude
        return claude.lifecycle_event(payload)

    def events(self, state="open", limit=50, after_ms=None):
        rows = self.store.list(
            state=state, limit=limit, after_ms=after_ms)
        return {
            "ok": True,
            "events": rows,
            "next_after_ms": max(
                (row["updated_at_ms"] for row in rows), default=after_ms),
        }

    def respond(
        self, event_id, *, revision, action, idempotency_key, text=None,
    ):
        event, duplicate = self.store.claim(
            event_id, revision, action, idempotency_key)
        if duplicate:
            return {"ok": True, "duplicate": True, "event": event}
        with self._adapter_lock:
            adapter = self.adapters.get(event["provider"])
        if adapter is None:
            self.store.mark_orphaned(event_id, "provider adapter unavailable")
            raise agent_events.EventConflict("provider adapter unavailable")
        try:
            adapter.respond(event, action, text=text)
        except Exception as exc:
            self.store.mark_orphaned(event_id, exc)
            raise agent_events.EventConflict(str(exc))
        self.store.mark_dispatched(event_id, idempotency_key)
        return {
            "ok": True,
            "duplicate": False,
            "event": self.store.get(event_id),
        }


def get():
    global _instance
    with _lock:
        if _instance is None:
            _instance = AgentGateway()
        return _instance


def reset_for_tests():
    global _instance
    with _lock:
        _instance = None
