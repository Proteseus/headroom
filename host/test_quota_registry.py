#!/usr/bin/env python3
"""Quota-provider registry: pools, headlines, and /usage providers[]."""

from __future__ import annotations

import unittest
from zoneinfo import ZoneInfo

import daily_burn
import headroom_server
import quota_samples
import sources_config


class QuotaRegistryTests(unittest.TestCase):
    def test_quota_sources_drive_pools_and_burn_ids(self):
        self.assertEqual(
            sources_config.BURN_SOURCE_IDS, ("claude", "codex", "cursor"))
        self.assertEqual(
            quota_samples.PROVIDERS, ("claude", "codex", "cursor"))
        self.assertEqual(
            {p.id for p in quota_samples.POOLS},
            {
                ("claude", "session"), ("claude", "week"),
                ("codex", "session"), ("codex", "week"),
                ("cursor", "total"), ("cursor", "auto"), ("cursor", "api"),
            },
        )

    def test_headline_pct_prefers_week_then_session(self):
        self.assertEqual(
            sources_config.headline_pct(
                "claude", {"week": {"pct": 40}, "session": {"pct": 10}}),
            40.0)
        self.assertEqual(
            sources_config.headline_pct(
                "claude", {"session": {"pct": 10}}),
            10.0)

    def test_headline_pct_cursor_falls_back_to_max(self):
        self.assertEqual(
            sources_config.headline_pct(
                "cursor",
                {"auto": {"pct": 12}, "api": {"pct": 41}}),
            41.0)
        self.assertEqual(
            sources_config.headline_pct(
                "cursor", {"total": {"pct": 34}, "api": {"pct": 90}}),
            34.0)

    def test_sources_payload_includes_kind(self):
        state = sources_config.blank_state()
        rows = headroom_server._sources_payload(state)
        by_id = {row["id"]: row for row in rows}
        self.assertEqual(by_id["claude"]["kind"], "quota")
        self.assertEqual(by_id["vercel"]["kind"], "activity")

    def test_providers_payload_shape(self):
        state = sources_config.blank_state()
        state["claude"] = {
            "ok": True,
            "plan": "Max",
            "session": {"pct": 10, "resets_in_s": 3600, "window_s": 5 * 3600},
            "week": {"pct": 40, "resets_in_s": 86400, "window_s": 7 * 86400},
        }
        rows = headroom_server._providers_payload(state)
        self.assertEqual([r["id"] for r in rows],
                         ["claude", "codex", "cursor"])
        claude = rows[0]
        self.assertEqual(claude["accent"], "#D97757")
        self.assertEqual(claude["headline"], "week")
        self.assertEqual(claude["pools"]["week"]["pct"], 40)
        self.assertTrue(claude["pools"]["week"]["ring"])
        cursor = next(r for r in rows if r["id"] == "cursor")
        self.assertFalse(cursor["pools"]["auto"]["ring"])

    def test_daily_burn_series_includes_burns_map(self):
        daily_burn.reset_for_tests()
        row = daily_burn.series(tz=ZoneInfo("UTC"), days=1)[0]
        self.assertIn("burns", row)
        self.assertEqual(set(row["burns"]), set(sources_config.BURN_SOURCE_IDS))
        self.assertEqual(row["burns"]["claude"], row["claude"])


if __name__ == "__main__":
    unittest.main()
