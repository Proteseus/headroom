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

    def test_remote_question_window_allows_a_phone_to_respond(self):
        self.assertEqual(claude_code.QUESTION_WAIT_SECONDS, 120)

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
            "tool_use_id": "toolu_01ABC",
            "permission_reasons": ["Destructive operation"],
        }

    @staticmethod
    def field(event, key):
        for entry in event["detail"]["request"]:
            if entry["key"] == key:
                return entry
        raise AssertionError(f"request field {key} missing")

    def wait_for_event(self):
        deadline = time.time() + 2
        while time.time() < deadline:
            rows = self.store.list(state="open")
            if rows:
                return rows[0]
            time.sleep(0.01)
        self.fail("Claude permission did not enter the attention feed")

    def answer(self, event, action, text=None):
        claimed, duplicate = self.store.claim(
            event["id"], event["revision"], action, "phone-tap-1")
        self.assertFalse(duplicate)
        self.adapter.respond(claimed, action, text=text)
        self.store.mark_dispatched(event["id"], "phone-tap-1")

    def test_typed_reply_reaches_the_model_as_a_denial_with_words(self):
        """Claude's own third choice: no, and tell it what to do instead."""
        result = {}
        thread = threading.Thread(target=lambda: result.update(
            value=self.adapter.permission_request(
                self.permission(), wait_seconds=3)))
        thread.start()
        event = self.wait_for_event()
        self.assertEqual(event["title"], "acme")
        reply = next(a for a in event["actions"] if a["id"] == "reply")
        self.assertTrue(reply["accepts_text"])
        self.answer(event, "reply", text="  use pnpm, not npm  ")
        thread.join(timeout=2)
        decision = result["value"]["hookSpecificOutput"]["decision"]
        self.assertEqual(decision["behavior"], "deny")
        self.assertIn("use pnpm, not npm", decision["message"])
        self.assertIn("iPhone", decision["message"])

    def test_typed_answer_to_a_question_travels_the_reason_channel(self):
        result = {}
        thread = threading.Thread(target=lambda: result.update(
            value=self.adapter.question_request(
                self.question(), wait_seconds=3, mode="answer")))
        thread.start()
        event = self.wait_for_event()
        self.assertEqual(event["title"], "acme")
        self.assertIn("reply", [a["id"] for a in event["actions"]])
        self.answer(event, "reply", text="none of those, rebase instead")
        thread.join(timeout=2)
        output = result["value"]["hookSpecificOutput"]
        self.assertEqual(output["permissionDecision"], "deny")
        self.assertIn(
            "none of those, rebase instead",
            output["permissionDecisionReason"])

    def test_an_empty_reply_is_refused_rather_than_sent(self):
        thread = threading.Thread(target=lambda: self.adapter.permission_request(
            self.permission(), wait_seconds=2))
        thread.start()
        event = self.wait_for_event()
        claimed, _ = self.store.claim(
            event["id"], event["revision"], "reply", "k")
        with self.assertRaises(ValueError):
            self.adapter.respond(claimed, "reply", text="   ")
        # The request is still live, so the turn is not left hanging.
        self.adapter.respond(claimed, "decline")
        thread.join(timeout=3)
        self.assertFalse(thread.is_alive())

    def test_permission_allow_wakes_exact_hook_request(self):
        result = {}
        thread = threading.Thread(target=lambda: result.update(
            value=self.adapter.permission_request(
                self.permission(), wait_seconds=3)))
        thread.start()
        event = self.wait_for_event()
        self.assertEqual(event["provider"], "claude-code")
        self.assertEqual(event["title"], "acme")
        self.assertEqual(self.field(event, "command")["value"], "npm test")
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
        self.assertEqual(event["title"], "acme")
        self.assertEqual(event["summary"], "Claude is waiting for your input")
        self.adapter.lifecycle_event({
            "hook_event_name": "UserPromptSubmit",
            "session_id": "claude-session-1",
        })
        self.assertEqual(self.store.get(event["id"])["state"], "resolved")

    def test_permission_exposes_whole_request_not_just_a_summary(self):
        """An Edit is unapprovable if the phone only shows the file name."""
        payload = self.permission()
        payload["tool_name"] = "Edit"
        payload["tool_input"] = {
            "file_path": "/tmp/acme/app.ts",
            "old_string": "const port = 3000",
            "new_string": "const port = 8080",
            "replace_all": False,
        }
        thread = threading.Thread(target=lambda: self.adapter.permission_request(
            payload, wait_seconds=2))
        thread.start()
        event = self.wait_for_event()
        self.assertEqual(
            [entry["key"] for entry in event["detail"]["request"]],
            ["file_path", "old_string", "new_string", "replace_all"],
            "known tools keep the order a person reads them in",
        )
        self.assertEqual(self.field(event, "old_string")["value"],
                         "const port = 3000")
        self.assertEqual(self.field(event, "new_string")["value"],
                         "const port = 8080")
        self.assertEqual(self.field(event, "file_path")["kind"], "path")
        self.assertEqual(self.field(event, "replace_all")["kind"], "bool")
        self.answer(event, "decline")
        thread.join(timeout=2)

    def test_permission_carries_reasons_and_correlation_ids(self):
        thread = threading.Thread(target=lambda: self.adapter.permission_request(
            self.permission(), wait_seconds=2))
        thread.start()
        event = self.wait_for_event()
        self.assertEqual(event["detail"]["reasons"], ["Destructive operation"])
        self.assertEqual(event["detail"]["tool_use_id"], "toolu_01ABC")
        self.assertEqual(event["detail"]["tool_name"], "Bash")
        self.answer(event, "decline")
        thread.join(timeout=2)

    def test_oversized_tool_input_is_bounded_not_rejected(self):
        payload = self.permission()
        payload["tool_name"] = "Write"
        payload["tool_input"] = {
            "file_path": "/tmp/acme/big.txt",
            "content": "x" * 500_000,
        }
        thread = threading.Thread(target=lambda: self.adapter.permission_request(
            payload, wait_seconds=2))
        thread.start()
        event = self.wait_for_event()
        content = self.field(event, "content")
        self.assertTrue(content["truncated"])
        self.assertEqual(content["full_chars"], 500_000)
        self.assertLessEqual(len(content["value"]), 2000)
        self.answer(event, "decline")
        thread.join(timeout=2)

    def test_always_allow_returns_an_exact_match_rule(self):
        result = {}
        thread = threading.Thread(target=lambda: result.update(
            value=self.adapter.permission_request(
                self.permission(), wait_seconds=3)))
        thread.start()
        event = self.wait_for_event()
        self.assertIn(
            "approve_always", [a["id"] for a in event["actions"]])
        self.assertEqual(event["detail"]["permission_rule"], "Bash(npm test)")
        self.answer(event, "approve_always")
        thread.join(timeout=2)
        decision = result["value"]["hookSpecificOutput"]["decision"]
        self.assertEqual(decision["behavior"], "allow")
        self.assertEqual(
            decision["updatedPermissions"],
            [{"rule": "Bash(npm test)", "mode": "allow"}],
        )

    def test_interrupt_stops_the_turn_and_says_who_did_it(self):
        result = {}
        thread = threading.Thread(target=lambda: result.update(
            value=self.adapter.permission_request(
                self.permission(), wait_seconds=3)))
        thread.start()
        event = self.wait_for_event()
        action = next(a for a in event["actions"] if a["id"] == "interrupt")
        self.assertEqual(action["risk"], "destructive")
        self.assertTrue(action["requires_biometric"])
        self.answer(event, "interrupt")
        thread.join(timeout=2)
        decision = result["value"]["hookSpecificOutput"]["decision"]
        self.assertEqual(decision["behavior"], "deny")
        self.assertTrue(decision["interrupt"])
        self.assertIn("Headroom", decision["message"])

    def test_deny_does_not_interrupt(self):
        """Deny answers one request; the turn keeps going."""
        result = {}
        thread = threading.Thread(target=lambda: result.update(
            value=self.adapter.permission_request(
                self.permission(), wait_seconds=3)))
        thread.start()
        event = self.wait_for_event()
        self.answer(event, "decline")
        thread.join(timeout=2)
        self.assertNotIn(
            "interrupt", result["value"]["hookSpecificOutput"]["decision"])

    def test_allow_once_never_grants_a_durable_rule(self):
        result = {}
        thread = threading.Thread(target=lambda: result.update(
            value=self.adapter.permission_request(
                self.permission(), wait_seconds=3)))
        thread.start()
        event = self.wait_for_event()
        self.answer(event, "approve_once")
        thread.join(timeout=2)
        self.assertNotIn(
            "updatedPermissions",
            result["value"]["hookSpecificOutput"]["decision"],
        )

    def test_a_question_is_never_drawn_as_a_permission_request(self):
        """Allow once / Deny are not answers to "which of these?"."""
        payload = self.permission()
        payload["tool_name"] = "AskUserQuestion"
        payload["tool_input"] = {"questions": [{"question": "Which one?"}]}
        self.assertIsNone(
            self.adapter.permission_request(payload, wait_seconds=2))
        self.assertEqual(self.store.list(state="all"), [])

    def test_notify_shows_the_question_and_holds_nothing(self):
        """Both places: the terminal renders it, the phone shows it too."""
        payload = self.question()
        payload["tool_input"]["questions"].append({
            "question": "And what else?",
            "multiSelect": True,
            "options": [{"label": "A"}, {"label": "B"}],
        })
        self.assertEqual(self.adapter.question_request(payload), {})
        row = self.store.list(state="open")[0]
        self.assertEqual(row["kind"], "structured_question")
        self.assertEqual(row["title"], "acme")
        self.assertTrue(row["detail"]["answer_on_mac"])
        self.assertEqual([a["id"] for a in row["actions"]], ["dismiss"])
        # Every question, whatever its shape — two here, one multi-select.
        values = " ".join(f["value"] for f in row["detail"]["request"])
        self.assertIn("41 uncommitted files", values)
        self.assertIn("And what else?", values)

    def test_a_second_question_replaces_the_first(self):
        self.adapter.question_request(self.question())
        self.adapter.question_request(self.question())
        self.assertEqual(len(self.store.list(state="open")), 1)

    def test_rule_escapes_glob_characters_in_paths(self):
        rule = claude_code.permission_rule(
            "Edit", {"file_path": "/tmp/[2024-06] Reports/a.ts"})
        self.assertEqual(
            rule, r"Edit(/tmp/\[2024-06\] Reports/a.ts)")

    def test_no_rule_for_unruleable_or_absurd_inputs(self):
        self.assertIsNone(claude_code.permission_rule("WebFetch", {"url": "x"}))
        self.assertIsNone(claude_code.permission_rule("Bash", {"command": ""}))
        self.assertIsNone(
            claude_code.permission_rule("Bash", {"command": "a\nb"}))
        self.assertIsNone(
            claude_code.permission_rule("Bash", {"command": "x" * 600}))

    @staticmethod
    def question(options=None, **overrides):
        entry = {
            "question": "How should I handle the 41 uncommitted files?",
            "multiSelect": False,
            "options": options if options is not None else [
                {"label": "Two clean commits, push both",
                 "description": "Reviewable and revertable per project."},
                {"label": "One commit with everything"},
            ],
        }
        entry.update(overrides)
        return {
            "hook_event_name": "PreToolUse",
            "session_id": "claude-session-1",
            "cwd": "/tmp/acme",
            "tool_name": "AskUserQuestion",
            "tool_input": {"questions": [entry]},
        }

    def test_question_options_become_answers_carried_back_to_claude(self):
        result = {}
        thread = threading.Thread(target=lambda: result.update(
            value=self.adapter.question_request(
                self.question(), wait_seconds=3, mode="answer")))
        thread.start()
        event = self.wait_for_event()
        self.assertEqual(event["kind"], "structured_question")
        self.assertEqual(
            [a["label"] for a in event["actions"]],
            ["Two clean commits, push both", "One commit with everything",
             "Reply", "Ask on Mac"],
        )
        self.assertEqual(
            event["actions"][0]["description"],
            "Reviewable and revertable per project.",
            "an option carries the reason you would pick it",
        )
        self.assertEqual(
            event["detail"]["request"], [],
            "the summary is the question and the actions are the options, "
            "so a request block would print all of it twice",
        )
        self.answer(event, "choice_1")
        thread.join(timeout=2)
        output = result["value"]["hookSpecificOutput"]
        self.assertEqual(output["hookEventName"], "PreToolUse")
        self.assertEqual(output["permissionDecision"], "deny")
        self.assertIn(
            "One commit with everything", output["permissionDecisionReason"])
        self.assertEqual(self.store.get(event["id"])["state"], "resolved")

    def test_ask_on_mac_defers_without_answering(self):
        result = {}
        thread = threading.Thread(target=lambda: result.update(
            value=self.adapter.question_request(
                self.question(), wait_seconds=3, mode="answer")))
        thread.start()
        event = self.wait_for_event()
        self.answer(event, "ask_on_mac")
        thread.join(timeout=2)
        self.assertEqual(
            result["value"], {},
            "no decision, said the only way that is safe in every version")

    def test_unanswered_question_defers_to_the_mac(self):
        result = self.adapter.question_request(
            self.question(), wait_seconds=1, mode="answer")
        self.assertEqual(result, {})
        self.assertEqual(self.store.list(state="all")[0]["state"], "expired")

    def test_shapes_we_cannot_answer_still_show_up_read_only(self):
        """Never half-answered from here — but still worth seeing there."""
        cases = [
            self.question(multiSelect=True),
            self.question(options=[{"label": "Only one"}]),
            self.question(options=[
                {"label": f"Option {n}"} for n in range(9)]),
        ]
        many = {
            "hook_event_name": "PreToolUse",
            "session_id": "s",
            "tool_name": "AskUserQuestion",
            "tool_input": {"questions": [
                {"question": "A?", "options": [{"label": "x"}, {"label": "y"}]},
                {"question": "B?", "options": [{"label": "x"}, {"label": "y"}]},
            ]},
        }
        for payload in cases + [many]:
            self.assertEqual(
                self.adapter.question_request(
                    payload, wait_seconds=1, mode="answer"), {},
                "nothing is held and nothing is answered")
        for row in self.store.list(state="all"):
            self.assertEqual(
                [a["id"] for a in row["actions"]], ["dismiss"],
                "read-only: the only place to answer these is the Mac")

    def test_finished_notices_replace_rather_than_stack(self):
        def finished(session="claude-session-1"):
            return self.adapter.lifecycle_event({
                "hook_event_name": "Stop",
                "session_id": session,
                "cwd": "/tmp/acme",
            })

        first = finished()
        second = finished()
        third = finished("claude-session-2")
        self.assertEqual(second["title"], "acme")
        self.assertEqual(
            second["summary"], "Ready for your next instruction")
        self.assertEqual(self.store.get(first["id"])["state"], "resolved")
        open_rows = self.store.list(state="open")
        self.assertEqual(
            {row["id"] for row in open_rows}, {second["id"], third["id"]},
            "one row per session, newest wins, other sessions untouched",
        )

    def test_a_notice_never_closes_a_pending_approval(self):
        thread = threading.Thread(target=lambda: self.adapter.permission_request(
            self.permission(), wait_seconds=3))
        thread.start()
        approval = self.wait_for_event()
        self.adapter.lifecycle_event({
            "hook_event_name": "Stop",
            "session_id": approval["session_id"],
            "cwd": "/tmp/acme",
        })
        self.assertEqual(
            self.store.get(approval["id"])["state"], "pending",
            "superseding is scoped by kind",
        )
        self.answer(approval, "decline")
        thread.join(timeout=2)

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
