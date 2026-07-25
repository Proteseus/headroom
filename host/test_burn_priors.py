#!/usr/bin/env python3
"""The token-history prior, and the window-alignment trap it fell into.

The first version divided the window's percent by a *rolling 7-day* token
total. Anthropic's weekly window rolls from its own start, so on a window that
opened two hours ago that compared "4% used since 09:00" against a week of
work, and produced an estimate ~60x too low. These tests pin the denominator
to the same window as the numerator.
"""

from __future__ import annotations

import unittest
from unittest.mock import patch

import headroom_server
import oauth_usage


NOW = 1_800_000_000.0
WEEK_S = oauth_usage.WEEK_WINDOW_S
HISTORY = {"avg_cost_per_active_day": 300.0}


def quota(pct, elapsed_s):
    return {"claude": {"ok": True, "week": {
        "pct": pct,
        "resets_in_s": WEEK_S - elapsed_s,
        "window_s": WEEK_S,
    }}}


class BurnPriorTests(unittest.TestCase):
    def prior(self, state, cost, history=HISTORY):
        with patch.object(headroom_server, "_cost_since", return_value=cost):
            return headroom_server._burn_priors(state, history, NOW)

    def test_scales_window_cost_to_a_daily_rate(self):
        # 4% cost $60 so far; a typical day costs $300, so ~20%/day.
        got = self.prior(quota(4.0, 6 * 3600), cost=60.0)
        self.assertAlmostEqual(got["claude"], 20.0, places=1)

    def test_denominator_follows_the_window_not_a_rolling_week(self):
        """Same percent and same daily average, two window ages.

        A younger window has less cost behind it, so each percent is worth
        more, so the daily estimate is higher. If the denominator were a fixed
        rolling week both would come out identical — that was the bug.
        """
        young = self.prior(quota(4.0, 3 * 3600), cost=30.0)
        old = self.prior(quota(4.0, 5 * 24 * 3600), cost=900.0)
        self.assertGreater(young["claude"], old["claude"])

    def test_withheld_while_the_window_is_too_young(self):
        self.assertEqual(self.prior(quota(4.0, 600), cost=60.0), {})

    def test_withheld_below_a_meaningful_percent(self):
        # Sub-1% is rounding noise on Anthropic's side, not a signal.
        self.assertEqual(self.prior(quota(0.4, 6 * 3600), cost=60.0), {})

    def test_withheld_without_enough_cost_behind_it(self):
        self.assertEqual(self.prior(quota(4.0, 6 * 3600), cost=0.10), {})

    def test_withheld_without_history(self):
        self.assertEqual(self.prior(quota(4.0, 6 * 3600), cost=60.0,
                                    history=None), {})

    def test_absurd_ratios_are_rejected(self):
        # A trivial cost behind a large percent implies a broken ratio.
        self.assertEqual(self.prior(quota(90.0, 6 * 3600), cost=1.5), {})

    def test_missing_or_malformed_quota_is_survivable(self):
        self.assertEqual(self.prior({}, cost=60.0), {})
        self.assertEqual(self.prior({"claude": {"ok": True}}, cost=60.0), {})
        self.assertEqual(
            self.prior({"claude": {"week": {"pct": "nope"}}}, cost=60.0), {})

    def test_only_claude_gets_a_prior(self):
        # Codex and Cursor keep no local log to calibrate against.
        got = self.prior(quota(4.0, 6 * 3600), cost=60.0)
        self.assertEqual(list(got), ["claude"])


if __name__ == "__main__":
    unittest.main()
