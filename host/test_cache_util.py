#!/usr/bin/env python3
"""Last-good cache: what a replay is, and how old it says it is."""

from __future__ import annotations

import email.utils
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


class RateLimitTests(unittest.TestCase):
    """A 429 has to slow the caller down, including a caller in a hurry."""

    def test_a_strike_holds_the_next_attempt_off(self):
        cache = {}
        cache_util.store(cache, NOW, {"ok": True, "plan": "Max"})
        wait = cache_util.note_rate_limit(cache, NOW)
        self.assertEqual(wait, cache_util.RATE_LIMIT_BACKOFF_S[0])
        self.assertTrue(cache_util.fresh(cache, NOW + wait - 1, 60, 20))
        self.assertFalse(cache_util.fresh(cache, NOW + wait + 1, 60, 20))

    def test_consecutive_strikes_escalate_and_then_cap(self):
        cache = {}
        cache_util.store(cache, NOW, {"ok": True, "plan": "Max"})
        waits = [cache_util.note_rate_limit(cache, NOW) for _ in range(6)]
        self.assertEqual(waits[:4], list(cache_util.RATE_LIMIT_BACKOFF_S))
        self.assertEqual(waits[4:], [cache_util.RATE_LIMIT_BACKOFF_S[-1]] * 2)

    def test_a_good_fetch_clears_the_strikes(self):
        cache = {}
        cache_util.store(cache, NOW, {"ok": True, "plan": "Max"})
        cache_util.note_rate_limit(cache, NOW)
        cache_util.note_rate_limit(cache, NOW)
        cache_util.store(cache, NOW + 600, {"ok": True, "plan": "Max"})
        self.assertEqual(
            cache_util.note_rate_limit(cache, NOW + 700),
            cache_util.RATE_LIMIT_BACKOFF_S[0])

    def test_backoff_outranks_a_forced_refresh(self):
        # Settings, the phone and the board's long-press all arrive as force.
        # They are what a user reaches for when the numbers look wrong, which
        # is exactly when the backoff is running.
        cache = {}
        cache_util.store(cache, NOW, {"ok": True, "plan": "Max"})
        cache_util.note_rate_limit(cache, NOW)
        self.assertTrue(cache_util.fresh(cache, NOW + 10, 60, 20, force=True))

    def test_a_first_ever_fetch_is_never_held_off(self):
        # Nothing cached means nothing to serve, so a backoff would leave the
        # source blank rather than merely stale.
        cache = {"retry_at": NOW + 600}
        self.assertFalse(cache_util.fresh(cache, NOW, 60, 20))

    def test_retry_after_seconds_wins_over_the_schedule(self):
        cache = {}
        cache_util.store(cache, NOW, {"ok": True, "plan": "Max"})
        self.assertEqual(cache_util.note_rate_limit(cache, NOW, "45"), 45.0)

    def test_retry_after_accepts_an_http_date(self):
        cache = {}
        cache_util.store(cache, NOW, {"ok": True, "plan": "Max"})
        stamp = email.utils.formatdate(NOW + 120, usegmt=True)
        self.assertAlmostEqual(
            cache_util.note_rate_limit(cache, NOW, stamp), 120.0, delta=1.0)

    def test_a_retry_after_in_the_past_means_now_not_forever(self):
        self.assertEqual(
            cache_util.parse_retry_after(
                email.utils.formatdate(NOW - 500, usegmt=True), NOW), 0.0)

    def test_an_absurd_retry_after_is_capped(self):
        cache = {}
        cache_util.store(cache, NOW, {"ok": True, "plan": "Max"})
        self.assertEqual(
            cache_util.note_rate_limit(cache, NOW, "999999"),
            float(cache_util.RATE_LIMIT_CEILING_S))

    def test_a_junk_retry_after_falls_back_to_the_schedule(self):
        self.assertIsNone(cache_util.parse_retry_after("soonish"))
        self.assertIsNone(cache_util.parse_retry_after(""))
        self.assertIsNone(cache_util.parse_retry_after(None))


if __name__ == "__main__":
    unittest.main()
