"""HTTP contract tests for the provider-neutral attention API."""

import json
import socket
import unittest
from unittest import mock
from types import SimpleNamespace

import agent_events
import headroom_server


class FakeGateway:
    def __init__(self):
        self.calls = []

    def capabilities(self):
        return {"ok": True, "providers": [{"provider": "codex"}]}

    def configuration(self):
        return {
            "ok": True,
            "enabled": False,
            "codex_binary": "codex",
            "provider": {"provider": "codex", "connection": "disabled"},
        }

    def reconfigure(self):
        self.calls.append(("reconfigure",))
        return self.configuration()

    def claude_permission(self, payload):
        self.calls.append(("claude_permission", payload))
        return {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {"behavior": "allow"},
            },
        }

    def claude_event(self, payload):
        self.calls.append(("claude_event", payload))

    def events(self, state="open", limit=50, after_ms=None):
        self.calls.append(("events", state, limit, after_ms))
        return {"ok": True, "events": [], "next_after_ms": after_ms}

    def respond(self, event_id, **values):
        self.calls.append(("respond", event_id, values))
        if event_id == "missing":
            raise agent_events.EventNotFound("attention event not found")
        return {
            "ok": True,
            "duplicate": False,
            "event": {"id": event_id, "state": "responding"},
        }


class AgentHTTPTests(unittest.TestCase):
    def setUp(self):
        self.gateway = FakeGateway()
        self.patcher = mock.patch(
            "headroom_server.agent_gateway.get", return_value=self.gateway)
        self.patcher.start()

    def tearDown(self):
        self.patcher.stop()

    def request(self, method, path, body=None):
        server_socket, client_socket = socket.socketpair()
        try:
            payload = json.dumps(body).encode() if body is not None else b""
            lines = [
                f"{method} {path} HTTP/1.0",
                "Host: localhost",
            ]
            if body is not None:
                lines.extend([
                    "Content-Type: application/json",
                    f"Content-Length: {len(payload)}",
                ])
            raw = ("\r\n".join(lines) + "\r\n\r\n").encode() + payload
            client_socket.sendall(raw)
            client_socket.shutdown(socket.SHUT_WR)
            headroom_server.Handler(
                server_socket, ("127.0.0.1", 12345),
                SimpleNamespace(server_port=8737))
            server_socket.close()
            response = b""
            while True:
                chunk = client_socket.recv(65536)
                if not chunk:
                    break
                response += chunk
        finally:
            server_socket.close()
            client_socket.close()
        headers, payload = response.split(b"\r\n\r\n", 1)
        status = int(headers.split(b" ", 2)[1])
        return status, json.loads(payload)

    def get(self, path):
        return self.request("GET", path)

    def post(self, path, body):
        return self.request("POST", path, body)

    def test_capabilities_and_incremental_event_list(self):
        status, capabilities = self.get("/agents/capabilities")
        self.assertEqual(status, 200)
        self.assertEqual(capabilities["providers"][0]["provider"], "codex")
        status, events = self.get(
            "/attention/events?state=pending&limit=7&after_ms=100")
        self.assertEqual(status, 200)
        self.assertEqual(events["events"], [])
        self.assertIn(("events", "pending", 7, 100), self.gateway.calls)

    def test_response_route_forwards_concurrency_fields(self):
        status, result = self.post("/attention/events/evt_123/respond", {
            "revision": 4,
            "action": "approve_once",
            "idempotency_key": "tap-1",
        })
        self.assertEqual(status, 200)
        self.assertEqual(result["event"]["state"], "responding")
        self.assertIn((
            "respond",
            "evt_123",
            {
                "revision": 4,
                "action": "approve_once",
                "idempotency_key": "tap-1",
            },
        ), self.gateway.calls)

    @mock.patch(
        "headroom_server.app_config.set_agent_gateway",
        return_value={"enabled": True, "codex_binary": "/opt/codex"},
    )
    def test_mac_can_configure_gateway(self, set_gateway):
        status, current = self.get("/agents/config")
        self.assertEqual(status, 200)
        self.assertFalse(current["enabled"])
        status, _result = self.post("/agents/config", {
            "enabled": True,
            "codex_binary": "/opt/codex",
        })
        self.assertEqual(status, 200)
        set_gateway.assert_called_once_with(
            enabled=True, codex_binary_value="/opt/codex")
        self.assertIn(("reconfigure",), self.gateway.calls)

    def test_missing_event_maps_to_not_found(self):
        status, result = self.post("/attention/events/missing/respond", {
            "revision": 1,
            "action": "decline",
            "idempotency_key": "tap-1",
        })
        self.assertEqual(status, 404)
        self.assertEqual(result["error"], "attention event not found")

    def test_claude_permission_hook_returns_provider_decision(self):
        payload = {
            "hook_event_name": "PermissionRequest",
            "session_id": "claude-1",
            "tool_name": "Bash",
            "tool_input": {"command": "npm test"},
        }
        status, result = self.post(
            "/agents/hooks/claude/permission", payload)
        self.assertEqual(status, 200)
        self.assertEqual(
            result["hookSpecificOutput"]["decision"]["behavior"], "allow")
        self.assertIn(("claude_permission", payload), self.gateway.calls)

    def test_claude_lifecycle_hook_is_accepted(self):
        payload = {
            "hook_event_name": "Notification",
            "session_id": "claude-1",
            "notification_type": "idle_prompt",
        }
        status, result = self.post("/agents/hooks/claude/event", payload)
        self.assertEqual(status, 200)
        self.assertEqual(result, {})
        self.assertIn(("claude_event", payload), self.gateway.calls)

    @mock.patch("headroom_server.claude_hooks.inspect")
    @mock.patch("headroom_server.claude_hooks.install")
    def test_mac_can_install_and_inspect_claude_hooks(
        self, install, inspect
    ):
        status_payload = {
            "provider": "claude-code",
            "state": "installed",
            "installed": True,
            "settings_path": "/tmp/settings.json",
        }
        inspect.return_value = status_payload
        install.return_value = status_payload
        status, current = self.get("/agents/claude/config")
        self.assertEqual(status, 200)
        self.assertTrue(current["installed"])
        status, result = self.post(
            "/agents/claude/config", {"action": "install"})
        self.assertEqual(status, 200)
        self.assertEqual(result["state"], "installed")
        install.assert_called_once_with(port=8737)


if __name__ == "__main__":
    unittest.main()
