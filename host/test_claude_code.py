"""Claude Code hook normalization and synchronous response tests."""

import os
import tempfile
import threading
import time
import unittest

import agent_events
import claude_code


class ClaudeCodeHooksTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = agent_events.EventStore(
            os.path.join(self.tmp.name, "attention.sqlite3"))
        self.adapter = claude_code.ClaudeCodeHooks(self.store)

    def tearDown(self):
        self.adapter.stop()
        self.tmp.cleanup()

    @staticmethod
    def permission():
        return {
            "hook_event_name": "PermissionRequest",
            "session_id": "claude-session-1",
            "cwd": "/tmp/acme",
            "tool_name": "Bash",
            "tool_input": {
                "command": "npm test",
                "description": "Run the test suite",
            },
            "permission_mode": "default",
        }

    def wait_for_event(self):
        deadline = time.time() + 2
        while time.time() < deadline:
            rows = self.store.list(state="open")
            if rows:
                return rows[0]
            time.sleep(0.01)
        self.fail("Claude permission did not enter the attention feed")

    def answer(self, event, action):
        claimed, duplicate = self.store.claim(
            event["id"], event["revision"], action, "phone-tap-1")
        self.assertFalse(duplicate)
        self.adapter.respond(claimed, action)
        self.store.mark_dispatched(event["id"], "phone-tap-1")

    def test_permission_allow_wakes_exact_hook_request(self):
        result = {}
        thread = threading.Thread(target=lambda: result.update(
            value=self.adapter.permission_request(
                self.permission(), wait_seconds=3)))
        thread.start()
        event = self.wait_for_event()
        self.assertEqual(event["provider"], "claude-code")
        self.assertEqual(event["detail"]["tool_input"]["command"], "npm test")
        self.answer(event, "approve_once")
        thread.join(timeout=2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(
            result["value"]["hookSpecificOutput"]["decision"]["behavior"],
            "allow",
        )
        self.assertEqual(self.store.get(event["id"])["state"], "resolved")

    def test_permission_deny_returns_documented_decision(self):
        result = {}
        thread = threading.Thread(target=lambda: result.update(
            value=self.adapter.permission_request(
                self.permission(), wait_seconds=3)))
        thread.start()
        event = self.wait_for_event()
        self.answer(event, "decline")
        thread.join(timeout=2)
        self.assertEqual(
            result["value"]["hookSpecificOutput"]["decision"]["behavior"],
            "deny",
        )
        self.assertEqual(self.store.get(event["id"])["state"], "declined")

    def test_timeout_returns_no_decision_and_expires_event(self):
        result = self.adapter.permission_request(
            self.permission(), wait_seconds=1)
        self.assertIsNone(result)
        event = self.store.list(state="all")[0]
        self.assertEqual(event["state"], "expired")

    def test_idle_notice_resolves_when_user_submits_next_prompt(self):
        event = self.adapter.lifecycle_event({
            "hook_event_name": "Notification",
            "session_id": "claude-session-1",
            "cwd": "/tmp/acme",
            "notification_type": "idle_prompt",
            "message": "Claude is waiting for your input",
        })
        self.assertEqual(event["kind"], "agent_waiting")
        self.adapter.lifecycle_event({
            "hook_event_name": "UserPromptSubmit",
            "session_id": "claude-session-1",
        })
        self.assertEqual(self.store.get(event["id"])["state"], "resolved")

    def test_permission_notification_does_not_duplicate_exact_request(self):
        result = self.adapter.lifecycle_event({
            "hook_event_name": "Notification",
            "session_id": "claude-session-1",
            "notification_type": "permission_prompt",
        })
        self.assertIsNone(result)
        self.assertEqual(self.store.list(state="all"), [])


if __name__ == "__main__":
    unittest.main()
