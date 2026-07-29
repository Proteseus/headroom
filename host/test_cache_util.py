#!/usr/bin/env python3
"""Last-good cache: what a replay is, and how old it says it is."""

from __future__ import annotations

import unittest

import cache_util


EMPTY = {"ok": False, "plan": None, "error": None}
NOW = 1_800_000_000.0


class KeepStaleTests(unittest.TestCase):
    def test_a_good_fetch_is_stamped_and_not_stale(self):
        cache = {}
        data = cache_util.store(cache, NOW, {"ok": True, "plan": "Max"})
        self.assertEqual(data["fetched_at"], NOW)
        self.assertFalse(data["stale"])

    def test_a_replay_is_marked_and_dated_from_the_last_real_fetch(self):
        cache = {}
        cache_util.store(cache, NOW, {"ok": True, "plan": "Max"})
        out = cache_util.keep_stale(cache, NOW + 4200, "boom", EMPTY)
        self.assertTrue(out["ok"])
        self.assertTrue(out["stale"])
        self.assertEqual(out["error"], "boom")
        self.assertEqual(out["stale_for_s"], 4200)

    def test_the_age_counts_from_the_fetch_not_from_the_last_attempt(self):
        # Every failing poll lands in keep_stale. If the clock restarted on
        # each one, a permanently broken source would read as fresh forever
        # and nothing downstream could ever escalate it.
        cache = {}
        cache_util.store(cache, NOW, {"ok": True, "plan": "Max"})
        for minute in range(1, 60):
            out = cache_util.keep_stale(
                cache, NOW + minute * 60, "boom", EMPTY)
        self.assertEqual(out["stale_for_s"], 59 * 60)

    def test_nothing_good_to_replay_fails_closed(self):
        out = cache_util.keep_stale({}, NOW, "boom", EMPTY)
        self.assertFalse(out["ok"])
        self.assertFalse(out["stale"])
        self.assertEqual(out["error"], "boom")

    def test_a_snapshot_without_the_stamp_ages_from_the_first_failure(self):
        # Disk caches written before `fetched_at` existed cannot say how old
        # they are. Ageing them from the first failure under-reports — the
        # data is older than this — but it never invents a number, and it
        # stops a source that broke before the upgrade from being exempt.
        cache = {"data": {"ok": True, "plan": "Max"}}
        first = cache_util.keep_stale(cache, NOW, "boom", EMPTY)
        self.assertEqual(first["stale_for_s"], 0)
        later = cache_util.keep_stale(cache, NOW + 3600, "boom", EMPTY)
        self.assertEqual(later["stale_for_s"], 3600)


if __name__ == "__main__":
    unittest.main()
