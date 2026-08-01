#!/usr/bin/env python3
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest.mock import patch
from zoneinfo import ZoneInfo

import daily_burn
import sources_config


TZ = ZoneInfo("Europe/Berlin")


class DailyBurnTests(unittest.TestCase):
    def setUp(self):
        daily_burn.reset_for_tests()
        self.tmp = tempfile.TemporaryDirectory()
        self.path = str(Path(self.tmp.name) / "daily_burn.json")
        self.patcher = patch.object(daily_burn, "STORE_PATH", self.path)
        self.patcher.start()

    def tearDown(self):
        self.patcher.stop()
        self.tmp.cleanup()
        daily_burn.reset_for_tests()

    def test_first_sample_sets_baseline_without_burn(self):
        row = daily_burn.observe(
            {"week": {"pct": 20}},
            {"week": {"pct": 10}},
            {"total": {"pct": 5}},
            tz=TZ,
            persist=True,
        )
        self.assertEqual(
            row, {sid: 0.0 for sid in sources_config.BURN_SOURCE_IDS})

    def test_positive_deltas_accumulate(self):
        daily_burn.observe(
            {"week": {"pct": 20}},
            {"week": {"pct": 10}},
            {"total": {"pct": 5}},
            tz=TZ,
        )
        row = daily_burn.observe(
            {"week": {"pct": 23.5}},
            {"week": {"pct": 12}},
            {"total": {"pct": 5.25}},
            tz=TZ,
        )
        self.assertEqual(row["claude"], 3.5)
        self.assertEqual(row["codex"], 2.0)
        self.assertEqual(row["cursor"], 0.25)

    def test_window_reset_does_not_count_negative(self):
        daily_burn.observe(
            {"week": {"pct": 40}},
            {"week": {"pct": 80}},
            {"total": {"pct": 50}},
            tz=TZ,
        )
        row = daily_burn.observe(
            {"week": {"pct": 2}},
            {"week": {"pct": 5}},
            {"total": {"pct": 1}},
            tz=TZ,
        )
        self.assertEqual(row["claude"], 0.0)
        self.assertEqual(row["codex"], 0.0)
        self.assertEqual(row["cursor"], 0.0)

        row = daily_burn.observe(
            {"week": {"pct": 6}},
            {"week": {"pct": 9}},
            {"total": {"pct": 3}},
            tz=TZ,
        )
        self.assertEqual(row["claude"], 4.0)
        self.assertEqual(row["codex"], 4.0)
        self.assertEqual(row["cursor"], 2.0)

    def test_series_fills_missing_days(self):
        daily_burn.observe(
            {"week": {"pct": 1}}, {"week": {"pct": 1}}, {"total": {"pct": 1}},
            tz=TZ,
        )
        daily_burn.observe(
            {"week": {"pct": 4}}, {"week": {"pct": 1}}, {"total": {"pct": 1}},
            tz=TZ,
        )
        rows = daily_burn.series(tz=TZ, days=3)
        self.assertEqual(len(rows), 3)
        # "Today" per the same tz daily_burn was told to use, not the
        # runner's system tz — CI runs in UTC, and Berlin can already be on
        # the next calendar day while UTC has not rolled over yet.
        self.assertEqual(
            rows[-1]["date"], datetime.now(TZ).date().isoformat())
        self.assertEqual(rows[-1]["claude"], 3.0)
        self.assertEqual(rows[-1]["total"], 3.0)
        self.assertEqual(rows[0]["total"], 0.0)

    def test_persists_across_reload(self):
        daily_burn.observe(
            {"week": {"pct": 10}}, {"week": {"pct": 0}}, {"total": {"pct": 0}},
            tz=TZ,
        )
        daily_burn.observe(
            {"week": {"pct": 15}}, {"week": {"pct": 0}}, {"total": {"pct": 0}},
            tz=TZ,
        )
        daily_burn.reset_for_tests()
        rows = daily_burn.series(tz=TZ, days=1)
        self.assertEqual(rows[0]["claude"], 5.0)


if __name__ == "__main__":
    unittest.main()
