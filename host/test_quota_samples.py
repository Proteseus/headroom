#!/usr/bin/env python3
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import quota_samples


NOW = 1_800_000_000.0
WEEK_S = 7 * 24 * 3600


def claude_payload(session_pct=10.0, week_pct=40.0, week_resets=3 * 24 * 3600):
    return {
        "ok": True,
        "plan": "Max",
        "session": {"pct": session_pct, "resets_in_s": 3600,
                    "window_s": 5 * 3600},
        "week": {"pct": week_pct, "resets_in_s": week_resets,
                 "window_s": WEEK_S},
    }


class ExtractTests(unittest.TestCase):
    def test_reads_pool_from_payload(self):
        got = quota_samples.extract("claude", "week", claude_payload())
        self.assertEqual(got, {"pct": 40.0, "window_s": WEEK_S,
                               "resets_in_s": 3 * 24 * 3600})

    def test_falls_back_to_provider_level_resets(self):
        # Cursor reports one billing cycle at the top level for both pools.
        payload = {
            "ok": True,
            "resets_in_s": 12 * 3600,
            "auto": {"pct": 55.0, "window_s": 30 * 24 * 3600},
        }
        got = quota_samples.extract("cursor", "auto", payload)
        self.assertEqual(got["resets_in_s"], 12 * 3600)
        self.assertEqual(got["pct"], 55.0)

    def test_missing_pool_is_none(self):
        self.assertIsNone(quota_samples.extract("claude", "week", {"ok": True}))

    def test_missing_window_is_none(self):
        # Cursor has no default window, so a payload without one is unusable.
        payload = {"ok": True, "auto": {"pct": 5.0, "resets_in_s": 60}}
        self.assertIsNone(quota_samples.extract("cursor", "auto", payload))

    def test_unknown_pool_is_none(self):
        self.assertIsNone(quota_samples.extract("claude", "nope", {"ok": True}))


class WindowStartTests(unittest.TestCase):
    def test_derived_from_elapsed(self):
        start = quota_samples.window_start_for(NOW, WEEK_S, 3 * 24 * 3600)
        self.assertEqual(start, int(NOW - 4 * 24 * 3600))

    def test_snaps_to_previous_within_tolerance(self):
        first = quota_samples.window_start_for(NOW, WEEK_S, 3 * 24 * 3600)
        # API jitter of a couple of minutes must not look like a new window.
        jittered = quota_samples.window_start_for(
            NOW + 120, WEEK_S, 3 * 24 * 3600, previous=first)
        self.assertEqual(jittered, first)

    def test_real_reset_starts_a_new_window(self):
        first = quota_samples.window_start_for(NOW, WEEK_S, 60)
        after = quota_samples.window_start_for(
            NOW + 120, WEEK_S, WEEK_S, previous=first)
        self.assertNotEqual(after, first)

    def test_stale_resets_do_not_fork_a_window(self):
        # A cached response after a wake repeats `resets_in_s` while the clock
        # moves on, walking the derived start forward. That is not a reset.
        first = quota_samples.window_start_for(NOW, WEEK_S, 3 * 24 * 3600)
        stale = quota_samples.window_start_for(
            NOW + 3600, WEEK_S, 3 * 24 * 3600, previous=first)
        self.assertEqual(stale, first)

    def test_large_jitter_short_of_a_window_holds(self):
        first = quota_samples.window_start_for(NOW, WEEK_S, 3 * 24 * 3600)
        # A single reading 16h out — seen in the wild — must not fork either.
        glitched = quota_samples.window_start_for(
            NOW, WEEK_S, 3 * 24 * 3600 + 16 * 3600, previous=first)
        self.assertEqual(glitched, first)

    def test_reset_observed_slightly_early_still_rolls(self):
        first = quota_samples.window_start_for(NOW, WEEK_S, 60)
        after = quota_samples.window_start_for(
            NOW, WEEK_S, WEEK_S - 300, previous=first)
        self.assertNotEqual(after, first)


class RecordTests(unittest.TestCase):
    def setUp(self):
        quota_samples.reset_for_tests()
        self.tmp = tempfile.TemporaryDirectory()
        self.path = str(Path(self.tmp.name) / "quota_samples.jsonl")
        self.patcher = patch.object(quota_samples, "STORE_PATH", self.path)
        self.patcher.start()

    def tearDown(self):
        self.patcher.stop()
        self.tmp.cleanup()
        quota_samples.reset_for_tests()

    def test_records_one_row_per_pool(self):
        rows = quota_samples.record({"claude": claude_payload()}, now=NOW)
        self.assertEqual({row["pool"] for row in rows}, {"session", "week"})
        self.assertTrue(all(row["provider"] == "claude" for row in rows))

    def test_skips_sources_that_are_not_ok(self):
        payload = claude_payload()
        payload["ok"] = False
        self.assertEqual(quota_samples.record({"claude": payload}, now=NOW), [])

    def test_dedupes_inside_one_bucket(self):
        quota_samples.record({"claude": claude_payload()}, now=NOW)
        again = quota_samples.record({"claude": claude_payload()}, now=NOW + 30)
        self.assertEqual(again, [])
        self.assertEqual(len(quota_samples.read(provider="claude")), 2)

    def test_writes_again_in_the_next_bucket(self):
        quota_samples.record({"claude": claude_payload()}, now=NOW)
        later = quota_samples.record(
            {"claude": claude_payload(week_pct=41.0)},
            now=NOW + quota_samples.BUCKET_S)
        self.assertEqual(len(later), 2)
        week = quota_samples.read(provider="claude", pool="week")
        self.assertEqual([row["pct"] for row in week], [40.0, 41.0])

    def test_restart_does_not_duplicate_a_bucket(self):
        quota_samples.record({"claude": claude_payload()}, now=NOW)
        quota_samples.reset_for_tests()  # simulate a host restart
        again = quota_samples.record({"claude": claude_payload()}, now=NOW + 60)
        self.assertEqual(again, [])
        self.assertEqual(len(quota_samples.read(provider="claude")), 2)

    def test_current_window_isolates_the_newest_window(self):
        quota_samples.record({"claude": claude_payload(week_resets=600)},
                             now=NOW)
        quota_samples.reset_for_tests()
        # Window reset: the meter refills and resets_in_s jumps back up.
        quota_samples.record(
            {"claude": claude_payload(week_pct=2.0, week_resets=WEEK_S)},
            now=NOW + 1200)
        self.assertEqual(len(quota_samples.windows("claude", "week")), 2)
        current = quota_samples.current_window("claude", "week")
        self.assertEqual([row["pct"] for row in current], [2.0])

    def test_current_window_ignores_an_orphaned_future_start(self):
        # A window_start further ahead than the live one, left behind by a bad
        # reading, must not become the pin — but a sample that actually fell
        # inside the live window still belongs on the curve.
        start = int(NOW - (WEEK_S - 600))
        rows = [
            {"t": NOW, "provider": "claude", "pool": "week", "pct": 40.0,
             "window_s": WEEK_S, "resets_in_s": 600, "window_start": start},
            {"t": NOW + 300, "provider": "claude", "pool": "week", "pct": 41.0,
             "window_s": WEEK_S, "resets_in_s": 600, "window_start": start + 99_000},
            {"t": NOW + 600, "provider": "claude", "pool": "week", "pct": 42.0,
             "window_s": WEEK_S, "resets_in_s": 600, "window_start": start},
        ]
        with open(self.path, "w") as handle:
            for row in rows:
                handle.write(json.dumps(row) + "\n")
        current = quota_samples.current_window("claude", "week")
        self.assertEqual([row["pct"] for row in current], [40.0, 41.0, 42.0])

    def test_current_window_reunites_forked_labels_by_time(self):
        # Codex-style resets_in freeze walks window_start forward each poll.
        # The burn from 0→18% lives on the early labels; later flat samples
        # wear new ones. Time-range selection puts them back on one curve.
        real_start = int(NOW - 24 * 3600)
        rows = [
            {"t": real_start + 3600, "provider": "codex", "pool": "week",
             "pct": 0.0, "window_s": WEEK_S, "resets_in_s": WEEK_S - 3600,
             "window_start": real_start},
            {"t": real_start + 7200, "provider": "codex", "pool": "week",
             "pct": 18.0, "window_s": WEEK_S, "resets_in_s": WEEK_S - 7200,
             "window_start": real_start},
            {"t": real_start + 12 * 3600, "provider": "codex", "pool": "week",
             "pct": 18.0, "window_s": WEEK_S, "resets_in_s": WEEK_S - 3600,
             "window_start": real_start + 5 * 3600},  # forked label
        ]
        with open(self.path, "w") as handle:
            for row in rows:
                handle.write(json.dumps(row) + "\n")
        current = quota_samples.current_window(
            "codex", "week", window_start=real_start, window_s=WEEK_S)
        self.assertEqual([row["pct"] for row in current], [0.0, 18.0, 18.0])

    def test_compact_drops_rows_past_retention(self):
        quota_samples.record({"claude": claude_payload()}, now=NOW)
        quota_samples.reset_for_tests()
        quota_samples.record({"claude": claude_payload()},
                             now=NOW + quota_samples.RETENTION_S + 3600)
        kept = quota_samples.compact(
            now=NOW + quota_samples.RETENTION_S + 3600)
        self.assertEqual(kept, 2)
        remaining = quota_samples.read(provider="claude")
        self.assertTrue(all(row["t"] > NOW for row in remaining))

    def test_read_survives_a_corrupt_line(self):
        quota_samples.record({"claude": claude_payload()}, now=NOW)
        with open(self.path, "a") as handle:
            handle.write("{not json\n")
        self.assertEqual(len(quota_samples.read(provider="claude")), 2)

    def test_missing_file_reads_as_empty(self):
        self.assertEqual(quota_samples.read(), [])
        self.assertEqual(quota_samples.current_window("claude", "week"), [])


if __name__ == "__main__":
    unittest.main()
