"""Canonical Codex reset feed — parse, match, no network in unit tests."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import codex_resets
import quota_samples


FEED = {
    "generated_at": "2026-08-04T08:00:00.000Z",
    "stats": {"total": 3},
    "events": [
        {
            "tweet_id": "1",
            "tweet_url": "https://x.com/thsottiaux/status/1",
            "text": "Reset one",
            "announced_at": "2026-07-25T19:17:12.000Z",
        },
        {
            "tweet_id": "2",
            "tweet_url": "https://x.com/thsottiaux/status/2",
            "text": "Reset two",
            "announced_at": "2026-07-28T03:09:23.000Z",
        },
        {
            "tweet_id": "3",
            "tweet_url": "https://x.com/thsottiaux/status/3",
            "text": "Reset three",
            "announced_at": "2026-08-01T03:32:37.000Z",
        },
    ],
}


class ParseTests(unittest.TestCase):
    def test_parse_feed_oldest_first_with_epoch(self):
        got = codex_resets.parse_feed(FEED)
        self.assertTrue(got["ok"])
        self.assertEqual(len(got["events"]), 3)
        self.assertEqual(got["events"][0]["tweet_id"], "1")
        self.assertEqual(got["events"][0]["t"], 1785007032)
        self.assertEqual(got["events"][-1]["tweet_id"], "3")
        self.assertEqual(got["url"], "https://codex-resets.com")


class MatchTests(unittest.TestCase):
    def test_local_detection_pairs_with_nearby_announcement(self):
        announced = codex_resets.parse_feed(FEED)["events"]
        observed = [
            {"t": 1785007200, "kind": "granted", "forgiven_pct": 100.0},
            {"t": 1785208200, "kind": "granted", "forgiven_pct": 18.0},
        ]
        merged, unmatched = codex_resets.match(observed, announced)
        self.assertEqual(len(merged), 2)
        self.assertEqual(merged[0]["source"], "both")
        self.assertEqual(merged[0]["tweet_id"], "1")
        self.assertEqual(merged[0]["t"], 1785007200)  # sample clock wins
        self.assertEqual(merged[0]["forgiven_pct"], 100.0)
        self.assertEqual(len(unmatched), 1)
        self.assertEqual(unmatched[0]["tweet_id"], "3")

    def test_far_away_detection_stays_local_only(self):
        # 18h before the Aug 1 announcement — a banked credit, not that tweet.
        announced = codex_resets.parse_feed(FEED)["events"]
        observed = [
            {"t": 1785488700, "kind": "granted", "forgiven_pct": 100.0},
        ]
        merged, unmatched = codex_resets.match(observed, announced)
        self.assertEqual(merged[0]["source"], "observed")
        self.assertIsNone(merged[0].get("tweet_id"))
        self.assertEqual(len(unmatched), 3)


class JournalMergeTests(unittest.TestCase):
    def setUp(self):
        quota_samples.reset_for_tests()
        codex_resets.reset_for_tests()
        self.tmp = tempfile.TemporaryDirectory()
        self.rolls_path = str(Path(self.tmp.name) / "quota_resets.jsonl")
        self.patcher = patch.object(
            quota_samples, "ROLLS_PATH", self.rolls_path)
        self.patcher.start()

    def tearDown(self):
        self.patcher.stop()
        self.tmp.cleanup()
        quota_samples.reset_for_tests()
        codex_resets.reset_for_tests()

    def test_rolls_for_keeps_unobserved_announcements(self):
        announced = codex_resets.parse_feed(FEED)["events"]
        now = 1785555600
        got = quota_samples.rolls_for(
            "codex", "week", [], now=now, announced=announced)
        ids = [event.get("tweet_id") for event in got]
        self.assertEqual(ids, ["1", "2", "3"])
        self.assertTrue(all(event["source"] == "announced" for event in got))

    def test_rolls_for_merges_sample_detection_onto_announcement(self):
        # One sample-detected grant that lands on announcement #1.
        rows = [
            {
                "t": 1785007000, "pct": 100.0, "resets_in_s": 6 * 24 * 3600,
                "window_s": 7 * 24 * 3600, "window_start": 1784700000,
                "window_end": 1784700000 + 7 * 24 * 3600,
            },
            {
                "t": 1785007200, "pct": 0.0, "resets_in_s": 7 * 24 * 3600,
                "window_s": 7 * 24 * 3600, "window_start": 1785007200,
                "window_end": 1785007200 + 7 * 24 * 3600,
            },
        ]
        # Force the window change to clear the grant bar used by rolls().
        rows[0]["window_end"] = 1785007200 + 5 * 24 * 3600
        announced = codex_resets.parse_feed(FEED)["events"]
        got = quota_samples.rolls_for(
            "codex", "week", rows, now=1785007200, announced=announced)
        both = [event for event in got if event.get("source") == "both"]
        self.assertEqual(len(both), 1)
        self.assertEqual(both[0]["tweet_id"], "1")
        self.assertEqual(both[0]["forgiven_pct"], 100.0)


if __name__ == "__main__":
    unittest.main()
