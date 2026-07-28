#!/usr/bin/env python3
"""Quota-provider registry: pools, headlines, and /usage providers[]."""

from __future__ import annotations

import os
import tempfile
import unittest
from unittest.mock import patch
from zoneinfo import ZoneInfo

import daily_burn
import headroom_server
import quota_samples
import sources_config


class QuotaRegistryTests(unittest.TestCase):
    def setUp(self):
        # providers[] follows the pinned order; keep it off this machine's.
        sources_config.reset_for_tests()
        self.tmp = tempfile.TemporaryDirectory()
        self.patcher = patch.object(
            sources_config, "STORE_PATH",
            os.path.join(self.tmp.name, "sources.json"))
        self.patcher.start()

    def tearDown(self):
        self.patcher.stop()
        self.tmp.cleanup()
        sources_config.reset_for_tests()

    def test_quota_sources_drive_pools_and_burn_ids(self):
        # Today's registry is the classic three; assertions stay registry-tied
        # so a fourth quota source does not require rewriting this contract.
        self.assertEqual(
            sources_config.BURN_SOURCE_IDS,
            tuple(s.id for s in sources_config.QUOTA_SOURCES))
        self.assertEqual(quota_samples.PROVIDERS, sources_config.BURN_SOURCE_IDS)
        self.assertTrue({"claude", "codex", "cursor"}.issubset(
            set(sources_config.BURN_SOURCE_IDS)))
        self.assertEqual(
            {p.id for p in quota_samples.POOLS},
            {
                (source.id, pool.id)
                for source in sources_config.QUOTA_SOURCES
                for pool in source.pools
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

    def test_every_source_lands_in_one_settings_group(self):
        """Onboarding and Settings render sections from these ids.

        Registry-tied on purpose: a new coding provider that forgets
        `group=GROUP_AI` defaults to devtools and would quietly show up under
        the wrong heading. That is what this catches.
        """
        self.assertEqual(
            {s.group for s in sources_config.SOURCES},
            set(sources_config.GROUP_IDS))
        ai_ids = {s.id for s in sources_config.sources_in_group(
            sources_config.GROUP_AI)}
        self.assertEqual(set(sources_config.BURN_SOURCE_IDS) - ai_ids, set())
        self.assertTrue({"claude", "codex", "cursor"}.issubset(ai_ids))
        self.assertEqual(
            ai_ids & {"plausible", "supabase", "github", "vercel", "git",
                      "local"},
            set())

    def test_group_travels_on_both_payloads(self):
        """Mac Settings reads /usage, onboarding reads /setup — same split."""
        rows = headroom_server._sources_payload(sources_config.blank_state())
        by_id = {row["id"]: row for row in rows}
        self.assertEqual(by_id["claude"]["group"], sources_config.GROUP_AI)
        self.assertEqual(
            by_id["plausible"]["group"], sources_config.GROUP_DEVTOOLS)

        setup = sources_config.detection_payload()
        setup_by_id = {row["id"]: row for row in setup["sources"]}
        self.assertEqual(setup_by_id["cursor"]["group"], sources_config.GROUP_AI)
        self.assertEqual(
            setup_by_id["github"]["group"], sources_config.GROUP_DEVTOOLS)
        self.assertEqual(setup["groups"], list(sources_config.GROUP_IDS))

    def test_providers_payload_shape(self):
        state = sources_config.blank_state()
        state["claude"] = {
            "ok": True,
            "plan": "Max",
            "session": {"pct": 10, "resets_in_s": 3600, "window_s": 5 * 3600},
            "week": {"pct": 40, "resets_in_s": 86400, "window_s": 7 * 86400},
        }
        rows = headroom_server._providers_payload(state)
        self.assertEqual(
            [r["id"] for r in rows],
            list(sources_config.BURN_SOURCE_IDS))
        claude = rows[0]
        self.assertEqual(claude["accent"], "#D97757")
        self.assertEqual(claude["headline"], "week")
        self.assertEqual(claude["pools"]["week"]["pct"], 40)
        self.assertTrue(claude["pools"]["week"]["ring"])
        cursor = next(r for r in rows if r["id"] == "cursor")
        self.assertFalse(cursor["pools"]["auto"]["ring"])

    def test_countdowns_follow_the_burndowns_held_window(self):
        # A source whose resets_in has drifted 3h past the reset the burndown
        # pinned. Every card in the document has to print the same number, or
        # the quota meter and the chart beside it disagree about the same week.
        state = sources_config.blank_state()
        state["claude"] = {
            "ok": True, "plan": "Max",
            "week": {"pct": 40, "resets_in_s": 86400 + 3 * 3600,
                     "window_s": 7 * 86400},
        }
        burndowns = {"claude": {"week": {"resets_in_s": 86400}}}
        rows = headroom_server._providers_payload(state, burndowns)
        week = next(r for r in rows if r["id"] == "claude")["pools"]["week"]
        self.assertEqual(week["resets_in_s"], 86400)
        self.assertEqual(week["resets_in"], "1d")

    def test_countdowns_fall_back_when_a_pool_has_no_burndown(self):
        state = sources_config.blank_state()
        state["claude"] = {
            "ok": True,
            "week": {"pct": 40, "resets_in_s": 86400, "window_s": 7 * 86400},
        }
        rows = headroom_server._providers_payload(state, {})
        week = next(r for r in rows if r["id"] == "claude")["pools"]["week"]
        self.assertEqual(week["resets_in_s"], 86400)

    def test_flattened_codex_countdown_follows_the_burndown(self):
        codex = {"ok": True,
                 "week": {"pct": 9, "resets_in_s": 999_999,
                          "window_s": 7 * 86400}}
        flat = headroom_server._flatten_codex(
            codex, {"codex": {"week": {"resets_in_s": 86400}}})
        self.assertEqual(flat["week_resets_in_s"], 86400)
        self.assertEqual(flat["week_resets_in"], "1d")

    def test_daily_burn_series_includes_burns_map(self):
        daily_burn.reset_for_tests()
        row = daily_burn.series(tz=ZoneInfo("UTC"), days=1)[0]
        self.assertIn("burns", row)
        self.assertEqual(set(row["burns"]), set(sources_config.BURN_SOURCE_IDS))
        self.assertEqual(row["burns"]["claude"], row["claude"])


if __name__ == "__main__":
    unittest.main()
