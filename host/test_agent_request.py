"""Provider-neutral request rendering: order, kinds, and bounds."""

import unittest

import agent_request


class AgentRequestFieldTests(unittest.TestCase):
    def keys(self, payload, tool_name=None):
        return [field["key"]
                for field in agent_request.fields(payload, tool_name)]

    def field(self, payload, tool_name, key):
        for entry in agent_request.fields(payload, tool_name):
            if entry["key"] == key:
                return entry
        raise AssertionError(f"missing field {key}")

    def test_known_tool_keeps_reading_order(self):
        payload = {
            "replace_all": True,
            "new_string": "b",
            "file_path": "/tmp/a.ts",
            "old_string": "a",
        }
        self.assertEqual(
            self.keys(payload, "Edit"),
            ["file_path", "old_string", "new_string", "replace_all"],
        )

    def test_unknown_tool_still_renders_in_sorted_order(self):
        payload = {"zeta": "1", "alpha": "2"}
        self.assertEqual(
            self.keys(payload, "mcp__acme__do_thing"), ["alpha", "zeta"])

    def test_extra_keys_follow_the_known_ones(self):
        payload = {"command": "ls", "shell": "zsh", "description": "list"}
        self.assertEqual(
            self.keys(payload, "Bash"), ["command", "description", "shell"])

    def test_kinds_come_from_key_and_value(self):
        payload = {
            "command": "ls",
            "file_path": "/tmp/x",
            "content": "line",
            "timeout": 120,
            "run_in_background": False,
            "options": {"a": 1},
            "note": "hello",
        }
        expected = {
            "command": "command",
            "file_path": "path",
            "content": "code",
            "timeout": "number",
            "run_in_background": "bool",
            "options": "json",
            "note": "text",
        }
        for key, kind in expected.items():
            self.assertEqual(self.field(payload, "Bash", key)["kind"], kind, key)

    def test_false_booleans_survive(self):
        """`replace_all: false` is a fact about the request, not an absence."""
        field = self.field(
            {"replace_all": False}, "Edit", "replace_all")
        self.assertEqual(field["value"], "false")

    def test_long_value_is_clipped_and_says_so(self):
        field = self.field(
            {"content": "y" * 9000}, "Write", "content")
        self.assertTrue(field["truncated"])
        self.assertEqual(field["full_chars"], 9000)
        self.assertEqual(len(field["value"]), agent_request.MAX_FIELD_CHARS)

    def test_short_value_is_not_marked_truncated(self):
        field = self.field({"command": "ls"}, "Bash", "command")
        self.assertFalse(field["truncated"])

    def test_total_budget_is_bounded_and_omissions_counted(self):
        payload = {f"key_{index:02d}": "z" * 3000 for index in range(30)}
        result = agent_request.fields(payload, "Unknown")
        total = sum(len(field["value"]) for field in result)
        self.assertLessEqual(total, agent_request.MAX_TOTAL_CHARS)
        self.assertGreater(result[-1].get("omitted_fields", 0), 0)

    def test_non_object_payloads_are_empty_not_an_error(self):
        for payload in (None, "command", [], 7):
            self.assertEqual(agent_request.fields(payload, "Bash"), [])


class AskUserQuestionTests(unittest.TestCase):
    payload = {
        "questions": [{
            "header": "Commit scope",
            "multiSelect": False,
            "question": "How should I handle the 41 uncommitted files?",
            "options": [
                {"label": "Two clean commits, push both",
                 "description": "One commit for the brand system."},
                {"label": "One commit with everything",
                 "description": "Fastest, but impossible to revert."},
            ],
        }],
    }

    def test_question_becomes_readable_fields_not_a_json_blob(self):
        result = agent_request.fields(self.payload, "AskUserQuestion")
        self.assertEqual([f["kind"] for f in result], ["text", "choice"])
        self.assertEqual(result[0]["label"], "Commit scope")
        self.assertEqual(
            result[0]["value"],
            "How should I handle the 41 uncommitted files?")
        self.assertEqual(
            result[1]["value"],
            "Two clean commits, push both — One commit for the brand system."
            "\nOne commit with everything — Fastest, but impossible to revert.")

    def test_summary_is_the_question_not_the_mechanism(self):
        self.assertEqual(
            agent_request.summary(self.payload, "AskUserQuestion"),
            "How should I handle the 41 uncommitted files?",
        )

    def test_malformed_questions_fall_back_to_generic_rendering(self):
        result = agent_request.fields(
            {"questions": "nope"}, "AskUserQuestion")
        self.assertEqual([f["key"] for f in result], ["questions"])


class AgentRequestSummaryTests(unittest.TestCase):
    def test_prefers_the_recognisable_field_over_the_first_one(self):
        payload = {"description": "Clean build", "command": "rm -rf build"}
        self.assertEqual(
            agent_request.summary(payload, "Bash"), "rm -rf build")

    def test_path_only_tools_read_as_a_sentence(self):
        self.assertEqual(
            agent_request.summary({"file_path": "/tmp/a.ts"}, "Write"),
            "Write /tmp/a.ts",
        )

    def test_falls_back_to_the_tool_name(self):
        self.assertEqual(
            agent_request.summary({"unknown": {}}, "Weird"), "Use Weird")

    def test_summary_is_one_line_and_bounded(self):
        result = agent_request.summary(
            {"command": "a\n" * 400}, "Bash")
        self.assertNotIn("\n", result)
        self.assertLessEqual(len(result), 240)


if __name__ == "__main__":
    unittest.main()
