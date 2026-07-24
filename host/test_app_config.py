"""Tests for ~/.headroom/config.json helpers."""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from unittest import mock

import app_config


class AppConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "config.json")
        self.patcher = mock.patch.object(app_config, "STORE_PATH", self.path)
        self.patcher.start()
        app_config.reload()

    def tearDown(self):
        self.patcher.stop()
        self.tmp.cleanup()
        app_config.reload()

    def test_defaults_without_file(self):
        self.assertEqual(app_config.timezone_name(), "Europe/Berlin")
        self.assertTrue(app_config.dev_root().endswith("/Dev"))
        self.assertIn("Michell Zappa", app_config.git_authors())
        self.assertEqual(app_config.vercel_team_slugs()[0], "ev-io")

    def test_overrides_from_file(self):
        with open(self.path, "w") as handle:
            json.dump({
                "timezone": "America/Los_Angeles",
                "dev_root": "~/Projects",
                "git_authors": ["Ada"],
                "vercel_team_slugs": ["acme"],
                "github_org_prefix": "acme/",
                "github_always_repos": ["acme/app"],
                "github_max_discovered": 2,
            }, handle)
        app_config.reload()
        self.assertEqual(app_config.timezone_name(), "America/Los_Angeles")
        self.assertTrue(app_config.dev_root().endswith("/Projects"))
        self.assertEqual(app_config.git_authors(), ["Ada"])
        self.assertEqual(app_config.vercel_team_slugs(), ("acme",))
        self.assertEqual(app_config.github_org_prefix(), "acme/")
        self.assertEqual(app_config.github_always_repos(), ("acme/app",))
        self.assertEqual(app_config.github_max_discovered(), 2)


class AttentionTests(unittest.TestCase):
    def test_critical_on_actions_fail(self):
        import headroom_server as hs
        doc = {
            "github": {"configured": True, "fail_count": 2},
            "supabase": {"configured": True, "alert_count": 0},
            "vercel": {"deployments": []},
            "codex": {"ok": True},
            "cursor": {"ok": True},
            "sources": [],
        }
        attention = hs._build_attention(doc)
        self.assertEqual(attention["level"], "critical")
        self.assertGreater(attention["score"], 0)
        self.assertTrue(attention["reasons"])

    def test_ok_when_clear(self):
        import headroom_server as hs
        attention = hs._build_attention({
            "github": {"configured": True, "fail_count": 0},
            "supabase": {"configured": True, "alert_count": 0},
            "vercel": {"deployments": [{"status": "ready"}]},
            "session_pct": 10,
            "week_pct": 20,
            "codex": {"ok": True, "week_pct": 30},
            "cursor": {"ok": True, "total_pct": 4},
            "sources": [{"enabled": True, "ok": True}],
        })
        self.assertEqual(attention["level"], "ok")
        self.assertEqual(attention["score"], 0)

    def test_drained_quota_does_not_nag(self):
        import headroom_server as hs
        attention = hs._build_attention({
            "github": {"configured": True, "fail_count": 0},
            "supabase": {"configured": True, "alert_count": 0},
            "vercel": {"deployments": []},
            "session_pct": 98,
            "week_pct": 90,
            "codex": {"ok": True, "session_pct": 100, "week_pct": 100},
            "cursor": {"ok": True, "total_pct": 99},
            "sources": [],
        })
        self.assertEqual(attention["level"], "ok")
        self.assertEqual(attention["reasons"], [])

    def test_provider_timeout_does_not_nag(self):
        import headroom_server as hs
        attention = hs._build_attention({
            "github": {"configured": True, "fail_count": 0},
            "supabase": {"configured": True, "alert_count": 0},
            "vercel": {"deployments": []},
            "codex": {"ok": False},
            "cursor": {"ok": False},
            "sources": [
                {
                    "id": "claude",
                    "title": "Claude",
                    "enabled": True,
                    "ok": False,
                    "configured": True,
                    "error": "HTTP Error 429: Too Many Requests",
                },
            ],
        })
        self.assertEqual(attention["level"], "ok")
        self.assertEqual(attention["reasons"], [])


class SpendParseTests(unittest.TestCase):
    def test_codex_spend_control(self):
        import codex_usage
        parsed = codex_usage.parse_usage({
            "plan_type": "team",
            "rate_limit": {},
            "spend_control": {
                "reached": True,
                "individual_limit": {
                    "limit": "500",
                    "used": "120.5",
                    "remaining": "0",
                    "used_percent": 24,
                    "source": "workspace_spend_controls",
                },
            },
        })
        self.assertEqual(parsed["spend"]["used_usd"], 120.5)
        self.assertEqual(parsed["spend"]["limit_usd"], 500.0)
        self.assertFalse(parsed["spend"]["reached"])
        self.assertEqual(parsed["spend"]["label"], "$120 / $500")

    def test_codex_spend_ignores_cents_scale_and_sticky_reached(self):
        import codex_usage
        parsed = codex_usage.parse_usage({
            "plan_type": "team",
            "rate_limit": {},
            "spend_control": {
                "reached": True,
                "individual_limit": {
                    "limit": "500",
                    "used": "46204.09",
                    "remaining": "0",
                    "used_percent": 0,
                    "source": "workspace_spend_controls",
                },
            },
        })
        self.assertEqual(parsed["spend"]["used_usd"], 462.04)
        self.assertEqual(parsed["spend"]["limit_usd"], 500.0)
        self.assertFalse(parsed["spend"]["reached"])
        self.assertEqual(parsed["spend"]["label"], "$462 / $500")

    def test_cursor_plan_spend(self):
        import cursor_usage
        parsed = cursor_usage.parse_usage({
            "planUsage": {
                "totalSpend": 1515,
                "includedSpend": 1515,
                "remaining": 485,
                "limit": 2000,
                "autoPercentUsed": 0,
                "apiPercentUsed": 10,
            },
            "spendLimitUsage": {
                "individualLimit": 3000,
                "individualRemaining": 2500,
            },
            "billingCycleStart": 0,
            "billingCycleEnd": 2_592_000_000,
        })
        self.assertEqual(parsed["spend"]["used_usd"], 15.15)
        self.assertEqual(parsed["spend"]["limit_usd"], 20.0)
        self.assertEqual(parsed["on_demand"]["used_usd"], 5.0)


if __name__ == "__main__":
    unittest.main()
