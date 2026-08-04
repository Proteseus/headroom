from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import opencode_usage


class OpenCodeUsageTests(unittest.TestCase):
    def setUp(self):
        opencode_usage._cache.update(t=0.0, data=None)

    def test_parses_current_export_v2(self):
        body = {
            "version": 2,
            "providers": {
                "opencode-go": {
                    "status": "ok",
                    "entries": [{
                        "name": "OpenCode Go Weekly",
                        "resultType": "quota",
                        "renderType": "percent",
                        "percentRemaining": 64,
                        "resetAt": 2_000,
                    }],
                },
            },
        }
        self.assertEqual(opencode_usage._entries(body)[0]["percentRemaining"], 64)

    @mock.patch.object(opencode_usage, "_bridge_command", return_value=["node"])
    def test_signed_in_requires_workspace_and_cookie_config(self, bridge):
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": tmp},
                                 clear=False):
                self.assertFalse(opencode_usage.signed_in())
                config = Path(tmp) / "opencode" / "opencode-quota"
                config.mkdir(parents=True)
                (config / "opencode-go.json").write_text(json.dumps({
                    "workspaceId": "wrk_test",
                    "authCookie": "cookie_test",
                }), encoding="utf-8")
                self.assertTrue(opencode_usage.signed_in())

    @mock.patch.object(opencode_usage, "signed_in", return_value=True)
    @mock.patch.object(opencode_usage, "_fetch_command", return_value=["collector"])
    @mock.patch.object(opencode_usage.subprocess, "run")
    def test_fetch_maps_windows_and_remaining_to_used(self, run, command, signed_in):
        run.return_value = subprocess.CompletedProcess(
            ["collector"], 0,
            stdout=json.dumps({"entries": [{
                "name": "OpenCode Go 5h",
                "resultType": "quota",
                "percentRemaining": 75,
                "resetInSec": 9_000,
            }]}),
            stderr="",
        )
        result = opencode_usage.fetch_quota(force=True)
        self.assertTrue(result["ok"])
        self.assertEqual(result["5h"]["pct"], 25)
        self.assertEqual(result["5h"]["resets_in_s"], 9_000)
        self.assertEqual(result["5h"]["pace_pct"], 50)
        self.assertEqual(run.call_args.kwargs["env"]["NODE_USE_ENV_PROXY"], "1")

    @mock.patch.object(opencode_usage, "signed_in", return_value=True)
    @mock.patch.object(opencode_usage, "_fetch_command", return_value=["collector"])
    @mock.patch.object(opencode_usage.subprocess, "run")
    def test_collector_setup_error_is_preserved(self, run, command, signed_in):
        run.return_value = subprocess.CompletedProcess(
            ["collector"], 0,
            stdout=json.dumps({"entries": [], "error": "missing authCookie"}),
            stderr="",
        )
        result = opencode_usage.fetch_quota(force=True)
        self.assertFalse(result["ok"])
        self.assertTrue(result["configured"])
        self.assertEqual(result["error"], "missing authCookie")


if __name__ == "__main__":
    unittest.main()
