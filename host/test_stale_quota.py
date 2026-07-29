#!/usr/bin/env python3
"""A stale quota reading must not be able to pass for a live one.

The bug these cover shipped as three separate half-truths that only added up
to a wrong answer together: a credential store that had lost its plan token
ended the search instead of continuing it, so the fetch could never recover on
its own; the retry clock stood in for the reading's age, so fifteen hours of
failure reported as one poll; and the countdown kept being derived from `now`
against a percentage that had stopped moving, so a dead window ticked to zero
in front of you. Percentages that hold at last-known are the design. A
countdown that keeps running is the lie.
"""
import json
import os
import tempfile
import time
import unittest
from unittest.mock import patch

import burndown
import cache_util
import headroom_server
import oauth_usage
import quota_samples

NOW = 1_800_000_000.0
WEEK_S = 7 * 24 * 3600


def quota_payload(**over):
    payload = {
        "ok": True,
        "plan": "Max 5x",
        "session": {"pct": 42.0, "resets_in_s": 2130, "window_s": 5 * 3600},
        "week": {"pct": 35.0, "resets_in_s": 3 * 24 * 3600,
                 "window_s": WEEK_S},
        "stale": False,
        "error": None,
        "fetched_at": NOW,
    }
    payload.update(over)
    return payload


class CredentialSearchTests(unittest.TestCase):
    """The store that ends the search has to be the one holding a token."""

    MCP_ONLY = {"mcpOAuth": {"plugin:x|abc": {"accessToken": "mcp-token"}}}
    GOOD = {"claudeAiOauth": {"accessToken": "plan-token",
                              "refreshToken": "r"}}

    def test_keychain_without_plan_token_falls_through_to_file(self):
        # The real shape that broke it: Claude Code keeps per-MCP-server OAuth
        # in the same Keychain item, and a blob left holding only `mcpOAuth`
        # used to end the search there and make the file unreachable.
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, ".credentials.json")
            with open(path, "w") as handle:
                json.dump(self.GOOD, handle)
            with patch.object(oauth_usage, "_read_keychain_blob",
                              return_value=self.MCP_ONLY), \
                 patch.object(oauth_usage, "CREDS_FILE", path):
                store, blob = oauth_usage._read_creds_blob()
        self.assertEqual(store, path)
        self.assertEqual(oauth_usage._oauth_block(blob)["accessToken"],
                         "plan-token")

    def test_keychain_wins_when_it_has_the_token(self):
        # Unchanged from before: the Keychain is still the preferred store, so
        # a refresh writes back where the CLI expects it.
        with patch.object(oauth_usage, "_read_keychain_blob",
                          return_value=self.GOOD), \
             patch.object(oauth_usage, "CREDS_FILE", "/nonexistent/creds"):
            store, blob = oauth_usage._read_creds_blob()
        self.assertEqual(store, "keychain")
        self.assertTrue(oauth_usage._oauth_block(blob))

    def test_token_nowhere_still_reports_against_a_real_store(self):
        # Nothing to find, but the error has to name a place that exists or it
        # reads as "Headroom lost your credentials".
        with patch.object(oauth_usage, "_read_keychain_blob",
                          return_value=self.MCP_ONLY), \
             patch.object(oauth_usage, "CREDS_FILE", "/nonexistent/creds"):
            store, blob = oauth_usage._read_creds_blob()
        self.assertEqual(store, "keychain")
        self.assertIsNone(oauth_usage._oauth_block(blob))

    def test_no_store_at_all_is_none(self):
        with patch.object(oauth_usage, "_read_keychain_blob",
                          return_value=None), \
             patch.object(oauth_usage, "CREDS_FILE", "/nonexistent/creds"):
            self.assertEqual(oauth_usage._read_creds_blob(), (None, None))


class StaleAgeTests(unittest.TestCase):
    """`fetched_at` records when the numbers were true, not when we last tried."""

    def test_store_stamps_fetched_at(self):
        cache = {"t": 0.0, "data": None, "err": None}
        data = cache_util.store(cache, NOW, {"ok": True})
        self.assertEqual(data["fetched_at"], NOW)

    def test_keep_stale_does_not_refresh_the_stamp(self):
        cache = {"t": 0.0, "data": None, "err": None}
        cache_util.store(cache, NOW, {"ok": True, "pct": 42})
        # Four hours of failing polls, an hour apart.
        for hour in range(1, 5):
            out = cache_util.keep_stale(
                cache, NOW + hour * 3600, "boom", {"ok": False})
        self.assertTrue(out["stale"])
        self.assertEqual(out["fetched_at"], NOW)
        self.assertEqual(cache_util.age_s(out, NOW + 4 * 3600), 4 * 3600)

    def test_fresh_payload_is_trusted(self):
        self.assertTrue(cache_util.trusted(quota_payload(), NOW))

    def test_briefly_stale_is_still_trusted(self):
        # A single missed poll is a blip; the numbers are seconds old and
        # everything derived from them still holds.
        payload = quota_payload(stale=True)
        self.assertTrue(cache_util.trusted(payload, NOW + 60))

    def test_long_stale_is_not_trusted(self):
        payload = quota_payload(stale=True)
        self.assertFalse(
            cache_util.trusted(payload, NOW + cache_util.TRUSTED_STALE_S + 1))

    def test_payload_without_a_stamp_is_taken_at_face_value(self):
        # An old snapshot must not make a working source look broken on the
        # first poll after an upgrade.
        payload = quota_payload(stale=True)
        del payload["fetched_at"]
        self.assertTrue(cache_util.trusted(payload, NOW + 10 * 3600))

    def test_disk_snapshot_without_a_stamp_ages_from_mtime(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(cache_util, "CACHE_DIR", tmp):
                path = os.path.join(tmp, "claude.json")
                with open(path, "w") as handle:
                    json.dump({"ok": True, "plan": "Max 5x"}, handle)
                os.utime(path, (NOW, NOW))
                data = cache_util.load_disk("claude")
        self.assertEqual(data["fetched_at"], NOW)
        self.assertEqual(cache_util.age_s(data, NOW + 900), 900)


class StaleDerivationTests(unittest.TestCase):
    """Nothing measured against `now` may be computed off a frozen reading."""

    def test_countdown_is_suppressed_when_untrusted(self):
        held = {"claude": {"session": {"resets_in_s": 1200}}}
        self.assertEqual(
            headroom_server._held_resets(held, "claude", "session", 999), 1200)
        self.assertIsNone(
            headroom_server._held_resets(
                held, "claude", "session", 999, trusted=False))

    def test_stale_provider_keeps_percentages_but_loses_the_countdown(self):
        stale = quota_payload(stale=True, error="no plan token")
        state = {"claude": stale}
        old = NOW + 15 * 3600
        with patch.object(time, "time", return_value=old):
            rows = headroom_server._providers_payload(state, burndowns={})
        claude = next(row for row in rows if row["id"] == "claude")
        self.assertTrue(claude["stale"])
        self.assertEqual(claude["age_s"], 15 * 3600)
        # Last-known is still worth showing. "Resets in 2m" is not.
        self.assertEqual(claude["pools"]["session"]["pct"], 42.0)
        self.assertIsNone(claude["pools"]["session"]["resets_in"])
        self.assertIsNone(claude["pools"]["session"]["pace_pct"])

    def test_stale_provider_draws_no_chart(self):
        stale = quota_payload(stale=True)
        old = NOW + 15 * 3600
        self.assertEqual(burndown.compute_all({"claude": stale}, now=old), {})
        # Same payload inside the blip window still charts.
        fresh = burndown.compute_all({"claude": stale}, now=NOW + 60)
        self.assertIn("claude", fresh)

    def test_stale_provider_is_not_sampled(self):
        stale = quota_payload(stale=True)
        old = NOW + 15 * 3600
        with patch.object(quota_samples, "_last_row", {}), \
             patch.object(quota_samples, "_seeded", True):
            rows = quota_samples.record(
                {"claude": stale}, now=old, persist=False)
        self.assertEqual(rows, [])

    def test_fresh_provider_is_still_sampled(self):
        with patch.object(quota_samples, "_last_row", {}), \
             patch.object(quota_samples, "_seeded", True):
            rows = quota_samples.record(
                {"claude": quota_payload()}, now=NOW, persist=False)
        self.assertEqual(
            sorted(row["pool"] for row in rows), ["session", "week"])


if __name__ == "__main__":
    unittest.main()
