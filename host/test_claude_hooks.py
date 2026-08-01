"""Managed Claude settings installation tests."""

import json
import os
import tempfile
import unittest

import claude_hooks


class ClaudeHookInstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, ".claude", "settings.json")
        os.makedirs(os.path.dirname(self.path))

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, value):
        with open(self.path, "w") as handle:
            json.dump(value, handle)

    def read(self):
        with open(self.path) as handle:
            return json.load(handle)

    def test_install_preserves_foreign_hooks_and_is_idempotent(self):
        foreign = {
            "matcher": "Bash",
            "hooks": [{"type": "command", "command": "/tmp/audit.sh"}],
        }
        self.write({"theme": "dark", "hooks": {"Stop": [foreign]}})
        first = claude_hooks.install(self.path, port=9876)
        second = claude_hooks.install(self.path, port=9876)
        self.assertEqual(first["state"], "installed")
        self.assertEqual(second["state"], "installed")
        value = self.read()
        self.assertEqual(value["theme"], "dark")
        self.assertIn(foreign, value["hooks"]["Stop"])
        for event in claude_hooks.EVENTS:
            managed = [
                entry for entry in value["hooks"][event]
                if claude_hooks._managed(entry)
            ]
            self.assertEqual(len(managed), 1)
        url = value["hooks"]["PermissionRequest"][-1]["hooks"][0]["url"]
        self.assertIn("127.0.0.1:9876", url)
        self.assertTrue(os.path.exists(self.path + ".bak-headroom"))

    def test_uninstall_removes_only_headroom_entries(self):
        self.write({"hooks": {
            "Stop": [{
                "matcher": "",
                "hooks": [{"type": "command", "command": "/tmp/keep.sh"}],
            }],
        }})
        claude_hooks.install(self.path)
        status = claude_hooks.uninstall(self.path)
        self.assertEqual(status["state"], "not_installed")
        remaining = self.read()["hooks"]["Stop"]
        self.assertEqual(remaining[0]["hooks"][0]["command"], "/tmp/keep.sh")

    def test_partial_install_is_reported_as_modified(self):
        self.write({"hooks": {
            "Notification": [claude_hooks._entry(8737, "Notification")],
        }})
        status = claude_hooks.inspect(self.path)
        self.assertEqual(status["state"], "modified_externally")

    def test_remote_question_hook_waits_long_enough_for_phone(self):
        entry = claude_hooks._entry(8737, "PreToolUse", "answer")
        self.assertEqual(entry["hooks"][0]["timeout"], 125)


if __name__ == "__main__":
    unittest.main()
