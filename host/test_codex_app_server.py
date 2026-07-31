"""Protocol normalization tests for the supervised Codex adapter."""

import io
import os
import tempfile
import unittest
from unittest import mock

import agent_events
import codex_app_server


class LiveProcess:
    stdin = object()

    @staticmethod
    def poll():
        return None


class ExitedProcess:
    stdin = object()

    def __init__(self, status=7, stderr=b"configuration failed\n"):
        self.stdout = io.BytesIO()
        self.stderr = io.BytesIO(stderr)
        self.returncode = status

    def poll(self):
        return self.returncode

    def wait(self, timeout=None):
        return self.returncode


class CodexAppServerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = agent_events.EventStore(
            os.path.join(self.tmp.name, "attention.sqlite3"))
        self.adapter = codex_app_server.CodexAppServer(
            self.store, binary="codex", log=lambda *_args, **_kwargs: None)
        self.sent = []
        self.adapter._send = self.sent.append
        self.adapter._process = LiveProcess()

    def tearDown(self):
        self.tmp.cleanup()

    def approval(self, method=codex_app_server.COMMAND_APPROVAL, request_id=42):
        params = {
            "threadId": "thread-1",
            "turnId": "turn-1",
            "itemId": "item-1",
            "reason": "Tests need to run",
        }
        if method == codex_app_server.COMMAND_APPROVAL:
            params.update({"command": "make test", "cwd": "/tmp/project"})
        self.adapter.ingest_for_test({
            "id": request_id,
            "method": method,
            "params": params,
        })
        return self.store.list(state="open")[0]

    def test_command_approval_round_trips_to_json_rpc_decision(self):
        event = self.approval()
        self.assertEqual(event["kind"], "command_approval")
        self.assertEqual(event["detail"]["command"], "make test")
        self.assertTrue(
            next(action for action in event["actions"]
                 if action["id"] == "approve_once")["requires_biometric"])
        self.adapter.respond(event, "approve_once")
        self.assertEqual(
            self.sent, [{"id": 42, "result": {"decision": "accept"}}])

    def question(self, request_id=77, **overrides):
        entry = {
            "id": "q1",
            "header": "Rollout",
            "question": "How should I roll this out?",
            "options": [
                {"label": "Staged", "description": "One region first."},
                {"label": "All at once", "description": "Faster, riskier."},
            ],
        }
        entry.update(overrides)
        self.adapter.ingest_for_test({
            "id": request_id,
            "method": codex_app_server.USER_INPUT,
            "params": {
                "threadId": "thread-1",
                "turnId": "turn-1",
                "itemId": "item-1",
                "questions": [entry],
            },
        })
        rows = self.store.list(state="open")
        return rows[0] if rows else None

    def test_command_approval_exposes_the_parsed_actions_and_network(self):
        """Captured since the adapter was written; never reached a screen."""
        self.adapter.ingest_for_test({
            "id": 43,
            "method": codex_app_server.COMMAND_APPROVAL,
            "params": {
                "threadId": "t", "turnId": "u", "itemId": "i",
                "command": "curl https://example.com",
                "cwd": "/tmp/project",
                "commandActions": [{"kind": "network", "host": "example.com"}],
                "networkApprovalContext": {"policy": "managed"},
            },
        })
        event = self.store.list(state="open")[0]
        keys = [f["key"] for f in event["detail"]["request"]]
        self.assertEqual(
            keys[:2], ["command", "cwd"], "read in the order a person would")
        self.assertIn("commandActions", keys)
        self.assertIn("networkApprovalContext", keys)

    def test_question_options_become_answers_codex_can_read(self):
        event = self.question()
        self.assertEqual(event["kind"], "structured_question")
        self.assertEqual(
            [a["label"] for a in event["actions"]],
            ["Staged", "All at once", "Reply", "Ask on Mac", "Stop Codex"])
        self.assertEqual(event["actions"][0]["description"], "One region first.")
        self.assertEqual(
            event["detail"]["request"], [],
            "the summary is the question and the actions are the options")
        self.adapter.respond(event, "choice_1")
        self.assertEqual(self.sent, [{
            "id": 77,
            "result": {"answers": {"q1": {"answers": ["All at once"]}}},
        }])

    def test_typed_reply_is_a_first_class_codex_answer(self):
        event = self.question()
        reply = next(a for a in event["actions"] if a["id"] == "reply")
        self.assertTrue(reply["accepts_text"])
        self.adapter.respond(event, "reply", text="  neither, ship behind a flag ")
        self.assertEqual(self.sent, [{
            "id": 77,
            "result": {"answers": {
                "q1": {"answers": ["neither, ship behind a flag"]}}},
        }])

    def test_an_empty_codex_reply_is_refused(self):
        event = self.question()
        with self.assertRaises(ValueError):
            self.adapter.respond(event, "reply", text="  ")
        self.assertEqual(self.sent, [])

    def test_ask_on_mac_returns_no_answer(self):
        event = self.question()
        self.adapter.respond(event, "ask_on_mac")
        self.assertEqual(self.sent, [{"id": 77, "result": {"answers": {}}}])

    def test_a_secret_is_never_answerable_from_a_phone(self):
        self.assertIsNone(self.question(isSecret=True))
        self.assertEqual(self.sent, [{"id": 77, "result": {"answers": {}}}])

    def test_unanswerable_question_shapes_decline_without_a_row(self):
        for override in ({"options": [{"label": "Only one"}]},
                         {"options": [{"label": f"O{n}"} for n in range(9)]},
                         {"question": ""}):
            self.sent.clear()
            self.assertIsNone(self.question(**override))
            self.assertEqual(
                self.sent, [{"id": 77, "result": {"answers": {}}}])

    def test_interrupt_stops_the_turn_rather_than_answering(self):
        event = self.approval()
        self.adapter.respond(event, "interrupt")
        self.assertEqual(self.sent, [{
            "id": 101,
            "method": codex_app_server.TURN_INTERRUPT,
            "params": {"threadId": "thread-1", "turnId": "turn-1"},
        }])

    def answer_calls(self, replies):
        """Answer the adapter's own client requests, the way Codex would."""
        def send(message):
            self.sent.append(message)
            method = message.get("method")
            if method in replies:
                self.adapter.ingest_for_test(
                    {"id": message["id"], "result": replies[method]})
        self.adapter._send = send

    def test_starting_a_task_is_what_gives_approvals_somewhere_to_come_from(self):
        self.adapter._status = "ready"
        self.answer_calls({
            codex_app_server.THREAD_START: {"thread": {"id": "thread-9"}},
            codex_app_server.TURN_START: {"turn": {"id": "turn-9"}},
        })
        task = self.adapter.start_task(self.tmp.name, "  fix the flaky test  ")
        self.assertEqual(task["thread_id"], "thread-9")
        self.assertEqual(task["turn_id"], "turn-9")

        start = next(m for m in self.sent
                     if m.get("method") == codex_app_server.THREAD_START)
        self.assertEqual(start["params"]["cwd"], self.tmp.name)
        self.assertEqual(
            start["params"]["approvalPolicy"], "on-request",
            "approvals only reach Headroom when Codex is told to ask")

        turn = next(m for m in self.sent
                    if m.get("method") == codex_app_server.TURN_START)
        self.assertEqual(
            turn["params"]["input"],
            [{"type": "text", "text": "fix the flaky test"}])

    def test_steering_names_the_turn_it_was_meant_for(self):
        self.adapter._status = "ready"
        self.adapter._active_thread = "thread-9"
        self.adapter._active_turn = "turn-9"
        self.answer_calls({codex_app_server.TURN_STEER: {}})
        self.adapter.steer("  also update the changelog ")
        steer = next(m for m in self.sent
                     if m.get("method") == codex_app_server.TURN_STEER)
        self.assertEqual(steer["params"]["expectedTurnId"], "turn-9")
        self.assertEqual(
            steer["params"]["input"],
            [{"type": "text", "text": "also update the changelog"}])

    def test_a_finished_turn_is_no_longer_steerable(self):
        self.adapter._active_thread = "thread-9"
        self.adapter._active_turn = "turn-9"
        self.adapter.ingest_for_test({
            "method": codex_app_server.TURN_COMPLETED,
            "params": {"turn": {"id": "turn-9"}},
        })
        with self.assertRaises(RuntimeError):
            self.adapter.steer("too late")

    def test_a_task_needs_a_real_folder_and_words(self):
        self.adapter._status = "ready"
        with self.assertRaises(ValueError):
            self.adapter.start_task("/nope/not/here", "do a thing")
        with self.assertRaises(ValueError):
            self.adapter.start_task(self.tmp.name, "   ")

    def test_no_task_while_the_app_server_is_down(self):
        self.adapter._status = "disconnected"
        with self.assertRaises(RuntimeError):
            self.adapter.start_task(self.tmp.name, "do a thing")

    def test_a_turn_that_dies_says_so_instead_of_going_quiet(self):
        """The first real turn this adapter started stopped on out-of-credits
        and told nobody."""
        self.adapter.ingest_for_test({
            "method": codex_app_server.TURN_COMPLETED,
            "params": {"threadId": "thread-9", "turn": {
                "id": "turn-9",
                "error": {
                    "message": "Your workspace is out of credits.",
                    "codexErrorInfo": {"type": "usage_limit_exceeded"},
                },
            }},
        })
        row = self.store.list(state="open")[0]
        self.assertEqual(row["title"], "Codex stopped")
        self.assertIn("out of credits", row["summary"])
        self.assertEqual(row["detail"]["reasons"], ["usage_limit_exceeded"])
        self.assertEqual([a["id"] for a in row["actions"]], ["dismiss"])

    def test_a_clean_turn_raises_no_row(self):
        self.adapter.ingest_for_test({
            "method": codex_app_server.TURN_COMPLETED,
            "params": {"threadId": "t", "turn": {"id": "turn-ok"}},
        })
        self.assertEqual(self.store.list(state="open"), [])

    def test_file_approval_is_normalized_separately(self):
        event = self.approval(codex_app_server.FILE_APPROVAL)
        self.assertEqual(event["kind"], "file_approval")
        self.assertEqual(event["summary"], "Tests need to run")

    def test_provider_resolution_closes_the_event(self):
        event = self.approval(request_id="approval-1")
        self.adapter.ingest_for_test({
            "method": codex_app_server.REQUEST_RESOLVED,
            "params": {"requestId": "approval-1", "threadId": "thread-1"},
        })
        self.assertEqual(self.store.get(event["id"])["state"], "resolved")

    def test_turn_completion_closes_unanswered_event(self):
        event = self.approval()
        self.adapter.ingest_for_test({
            "method": codex_app_server.TURN_COMPLETED,
            "params": {"turn": {"id": "turn-1"}},
        })
        self.assertEqual(self.store.get(event["id"])["state"], "resolved")

    def test_malformed_approval_is_denied_without_entering_feed(self):
        self.adapter.ingest_for_test({
            "id": 9,
            "method": codex_app_server.COMMAND_APPROVAL,
            "params": {"threadId": "thread-1"},
        })
        self.assertEqual(self.store.list(state="all"), [])
        self.assertEqual(
            self.sent, [{"id": 9, "result": {"decision": "decline"}}])

    @mock.patch(
        "codex_app_server.app_config.agent_gateway_enabled",
        return_value=False,
    )
    def test_disabling_adapter_orphans_callbacks_from_previous_host(
        self, _enabled
    ):
        event = self.approval()
        self.adapter.start()
        self.assertEqual(self.store.get(event["id"])["state"], "orphaned")

    @mock.patch(
        "codex_app_server.app_config.agent_gateway_enabled",
        return_value=True,
    )
    @mock.patch("codex_app_server._bundled_candidates", return_value=[])
    @mock.patch("codex_app_server.shutil.which", return_value=None)
    def test_missing_executable_reports_error_without_retry_loop(
        self, _which, _candidates, _enabled
    ):
        self.adapter = codex_app_server.CodexAppServer(
            self.store, binary="codex", log=lambda *_args, **_kwargs: None)
        self.adapter._process = None
        self.adapter.start()
        status = self.adapter.capabilities()
        self.assertEqual(status["connection"], "disconnected")
        self.assertIn("not found", status["error"])
        self.assertIsNone(self.adapter._thread)

    @mock.patch("codex_app_server.shutil.which", return_value=None)
    def test_resolves_standard_user_install_outside_launchd_path(self, _which):
        with tempfile.TemporaryDirectory() as directory:
            binary = os.path.join(directory, "codex")
            with open(binary, "w", encoding="utf-8") as handle:
                handle.write("#!/bin/sh\n")
            os.chmod(binary, 0o700)
            with mock.patch(
                "codex_app_server._bundled_candidates",
                return_value=[binary],
            ):
                adapter = codex_app_server.CodexAppServer(
                    self.store,
                    binary="codex",
                    log=lambda *_args, **_kwargs: None,
                )
        self.assertEqual(adapter.binary, binary)
        self.assertTrue(adapter.capabilities()["available"])
        self.assertEqual(
            adapter.capabilities()["resolved_binary"],
            binary,
        )

    @mock.patch("codex_app_server.subprocess.Popen")
    def test_child_uses_stable_cwd_and_reports_stderr(self, popen):
        popen.return_value = ExitedProcess()
        # setUp asks resolve_binary("codex"). CI has no Codex on PATH, so the
        # resolved path is None and _run_once would assert before Popen — this
        # test is about the child spawn, not discovery.
        self.adapter.binary = "/mock/codex"
        with self.assertRaisesRegex(
            RuntimeError,
            "status 7.*configuration failed",
        ):
            self.adapter._run_once()
        self.assertEqual(
            popen.call_args.kwargs["cwd"],
            os.path.expanduser("~"),
        )
        self.assertEqual(
            popen.call_args.kwargs["stderr"],
            codex_app_server.subprocess.PIPE,
        )


if __name__ == "__main__":
    unittest.main()
