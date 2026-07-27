#!/usr/bin/env python3
import unittest
from zoneinfo import ZoneInfo

import burndown


TZ = ZoneInfo("Europe/Berlin")
NOW = 1_800_000_000.0
WEEK_S = 7 * 24 * 3600
DAY_S = 24 * 3600
RESETS = 3 * DAY_S          # 3 days left, so 4 days elapsed
WINDOW_START = int(NOW - (WEEK_S - RESETS))


def payload(week_pct, resets_in_s=RESETS):
    return {
        "ok": True,
        "plan": "Max",
        "week": {"pct": week_pct, "resets_in_s": resets_in_s,
                 "window_s": WEEK_S},
    }


def rows(start_remaining, end_remaining, span_s=DAY_S, step=300,
         resets_in_s=RESETS):
    """Linear sample history ending exactly at NOW."""
    out = []
    first = NOW - span_s
    steps = int(span_s // step)
    for i in range(steps + 1):
        t = first + i * step
        frac = (t - first) / span_s
        remaining = start_remaining + (end_remaining - start_remaining) * frac
        out.append({
            "t": int(t),
            "provider": "claude",
            "pool": "week",
            "pct": round(100.0 - remaining, 2),
            "window_s": WEEK_S,
            "resets_in_s": resets_in_s,
            "window_start": WINDOW_START,
        })
    return out


class ShapeTests(unittest.TestCase):
    def test_unusable_payload_is_none(self):
        self.assertIsNone(burndown.compute("claude", "week", {"ok": True}))

    def test_ideal_line_spans_the_window(self):
        got = burndown.compute("claude", "week", payload(60.0),
                               now=NOW, tz=TZ, rows=rows(60.0, 40.0))
        self.assertEqual(got["ideal"], [[WINDOW_START, 100.0],
                                        [WINDOW_START + WEEK_S, 0.0]])
        self.assertEqual(got["window_end"] - got["window_start"], WEEK_S)

    def test_remaining_is_the_inverse_of_used(self):
        got = burndown.compute("claude", "week", payload(60.0),
                               now=NOW, tz=TZ, rows=rows(60.0, 40.0))
        self.assertEqual(got["used_pct"], 60.0)
        self.assertEqual(got["remaining_pct"], 40.0)

    def test_ideal_remaining_tracks_elapsed_window(self):
        # 4 of 7 days elapsed, so an even spend leaves 3/7 = 42.9%.
        got = burndown.compute("claude", "week", payload(60.0),
                               now=NOW, tz=TZ, rows=rows(60.0, 40.0))
        self.assertAlmostEqual(got["ideal_remaining_pct"], 42.9, places=1)

    def test_series_is_capped_and_ordered(self):
        got = burndown.compute("claude", "week", payload(60.0), now=NOW, tz=TZ,
                               rows=rows(60.0, 40.0), points=48)
        actual = got["actual"]
        self.assertLessEqual(len(actual), 49)
        self.assertEqual([p[0] for p in actual],
                         sorted(p[0] for p in actual))
        self.assertEqual(actual[-1][1], 40.0)

    def test_empty_history_still_returns_a_point(self):
        got = burndown.compute("claude", "week", payload(60.0),
                               now=NOW, tz=TZ, rows=[])
        self.assertEqual(got["actual"], [[int(NOW), 40.0]])
        self.assertIsNone(got["burn_rate_pct"])


class ForecastTests(unittest.TestCase):
    def test_exhaustion_before_reset_is_critical(self):
        # 60% -> 40% over 24h is 20 points/day; 40 left runs out in 2 days,
        # inside the 3 days remaining on the window.
        got = burndown.compute("claude", "week", payload(60.0),
                               now=NOW, tz=TZ, rows=rows(60.0, 40.0))
        self.assertAlmostEqual(got["burn_rate_pct"], 20.0, places=1)
        self.assertAlmostEqual(got["exhausts_in_s"], 2 * DAY_S, delta=60)
        self.assertTrue(got["exhausts_before_reset"])
        self.assertEqual(got["status"], burndown.STATUS_CRITICAL)
        self.assertIn("run out", got["headline"])

    def test_slow_burn_with_slack_is_ok(self):
        got = burndown.compute("claude", "week", payload(45.0),
                               now=NOW, tz=TZ, rows=rows(60.0, 55.0))
        self.assertFalse(got["exhausts_before_reset"])
        self.assertEqual(got["status"], burndown.STATUS_OK)
        self.assertGreater(got["delta_pct"], 0)
        self.assertIn("On pace", got["headline"])

    def test_deficit_without_exhaustion_is_ahead(self):
        # Well under the ideal line, but burning slowly enough to survive.
        got = burndown.compute("claude", "week", payload(70.0),
                               now=NOW, tz=TZ, rows=rows(35.0, 30.0))
        self.assertLess(got["delta_pct"], -5)
        self.assertFalse(got["exhausts_before_reset"])
        self.assertEqual(got["status"], burndown.STATUS_AHEAD)
        self.assertIn("budget", got["headline"])
        self.assertAlmostEqual(got["allowance_pct"], 10.0, places=1)

    def test_too_little_history_makes_no_claim(self):
        got = burndown.compute("claude", "week", payload(60.0), now=NOW, tz=TZ,
                               rows=rows(41.0, 40.0, span_s=600, step=300))
        self.assertIsNone(got["burn_rate_pct"])
        self.assertIsNone(got["exhausts_at"])
        self.assertFalse(got["exhausts_before_reset"])
        self.assertIn("Collecting history", got["headline"])

    def test_flat_usage_never_exhausts(self):
        got = burndown.compute("claude", "week", payload(60.0),
                               now=NOW, tz=TZ, rows=rows(40.0, 40.0))
        self.assertEqual(got["burn_rate_pct"], 0.0)
        self.assertIsNone(got["exhausts_at"])
        self.assertEqual(got["status"], burndown.STATUS_OK)

    def test_flat_usage_still_projects_level_to_the_reset(self):
        # "Nothing is moving" is a forecast. Emitting no series would render
        # identically to having no measurement at all.
        got = burndown.compute("claude", "week", payload(60.0),
                               now=NOW, tz=TZ, rows=rows(40.0, 40.0))
        self.assertEqual(len(got["projected"]), 2)
        first, last = got["projected"]
        self.assertEqual(first[1], last[1])
        self.assertEqual(last[0], got["window_end"])

    def test_exhausted_pool_projects_nothing(self):
        got = burndown.compute("claude", "week", payload(100.0),
                               now=NOW, tz=TZ, rows=rows(5.0, 0.0))
        self.assertEqual(got["projected"], [])
        self.assertEqual(got["status"], burndown.STATUS_EXHAUSTED)

    def test_projection_stops_at_the_reset(self):
        got = burndown.compute("claude", "week", payload(60.0),
                               now=NOW, tz=TZ, rows=rows(60.0, 40.0))
        self.assertEqual(len(got["projected"]), 2)
        self.assertLessEqual(got["projected"][-1][0], got["window_end"])
        self.assertGreaterEqual(got["projected"][-1][1], 0.0)


class RateUnitTests(unittest.TestCase):
    """A 5h window in points-per-day reads as a 550%/day budget. Don't."""

    SESSION_S = 5 * 3600
    SESSION_RESETS = 3600

    def session_payload(self, pct):
        return {"ok": True, "session": {"pct": pct,
                                        "resets_in_s": self.SESSION_RESETS,
                                        "window_s": self.SESSION_S}}

    def session_rows(self, start_remaining, end_remaining, span_s=6000):
        start = int(NOW - (self.SESSION_S - self.SESSION_RESETS))
        out = []
        steps = int(span_s // 300)
        for i in range(steps + 1):
            t = NOW - span_s + i * 300
            frac = (t - (NOW - span_s)) / span_s
            remaining = start_remaining + (end_remaining - start_remaining) * frac
            out.append({"t": int(t), "pct": round(100.0 - remaining, 2),
                        "window_start": start})
        return out

    def test_short_window_rates_are_per_hour(self):
        got = burndown.compute("claude", "session", self.session_payload(70.0),
                               now=NOW, tz=TZ,
                               rows=self.session_rows(33.0, 30.0))
        self.assertEqual(got["rate_unit"], "hour")
        # 3 points over 6000s is 1.8 points/hour.
        self.assertAlmostEqual(got["burn_rate_pct"], 1.8, places=1)
        # 30 points left with 1h to go.
        self.assertAlmostEqual(got["allowance_pct"], 30.0, places=1)
        self.assertNotIn("/day", got["headline"])

    def test_long_window_rates_are_per_day(self):
        got = burndown.compute("claude", "week", payload(60.0),
                               now=NOW, tz=TZ, rows=rows(60.0, 40.0))
        self.assertEqual(got["rate_unit"], "day")
        self.assertIn("/day", got["headline"])

    def test_small_rates_keep_precision(self):
        # A slow burn must not round to "0%/day" in the sentence.
        got = burndown.compute("claude", "week", payload(70.0),
                               now=NOW, tz=TZ, rows=rows(30.2, 30.0))
        self.assertEqual(got["status"], burndown.STATUS_AHEAD)
        self.assertIn("0.2%/day", got["headline"])

    def test_single_point_is_singular(self):
        got = burndown.compute("claude", "week", payload(56.14),
                               now=NOW, tz=TZ, rows=rows(45.0, 43.86))
        self.assertEqual(got["status"], burndown.STATUS_OK)
        self.assertIn("1 point to spare", got["headline"])
        self.assertNotIn("1 points", got["headline"])


class PriorTests(unittest.TestCase):
    """Token history covers the window a fresh install can't fit a slope over."""

    def test_prior_forecasts_before_any_samples_exist(self):
        got = burndown.compute("claude", "week", payload(60.0), now=NOW, tz=TZ,
                               rows=[], prior_pct_per_day=20.0)
        self.assertEqual(got["rate_source"], "estimated")
        self.assertAlmostEqual(got["burn_rate_pct"], 20.0, places=1)
        # 40 left at 20/day runs out in 2 days, inside the 3 remaining.
        self.assertAlmostEqual(got["exhausts_in_s"], 2 * DAY_S, delta=60)
        self.assertEqual(got["status"], burndown.STATUS_CRITICAL)

    def test_estimated_headline_hedges(self):
        got = burndown.compute("claude", "week", payload(60.0), now=NOW, tz=TZ,
                               rows=[], prior_pct_per_day=20.0)
        self.assertIn("about 20%/day", got["headline"])
        self.assertIn("Based on your recent usage", got["headline"])

    def test_measured_samples_beat_the_prior(self):
        # A wildly wrong prior must not survive contact with real data.
        got = burndown.compute("claude", "week", payload(60.0), now=NOW, tz=TZ,
                               rows=rows(60.0, 40.0), prior_pct_per_day=999.0)
        self.assertEqual(got["rate_source"], "measured")
        self.assertAlmostEqual(got["burn_rate_pct"], 20.0, places=1)
        self.assertNotIn("about", got["headline"])

    def test_no_prior_and_no_samples_makes_no_claim(self):
        got = burndown.compute("claude", "week", payload(60.0),
                               now=NOW, tz=TZ, rows=[])
        self.assertIsNone(got["rate_source"])
        self.assertIsNone(got["burn_rate_pct"])
        self.assertIn("Collecting history", got["headline"])

    def test_prior_is_scaled_into_the_pool_unit(self):
        got = burndown.compute(
            "claude", "session",
            {"ok": True, "session": {"pct": 70.0, "resets_in_s": 3600,
                                     "window_s": 5 * 3600}},
            now=NOW, tz=TZ, rows=[], prior_pct_per_day=24.0)
        self.assertEqual(got["rate_unit"], "hour")
        self.assertAlmostEqual(got["burn_rate_pct"], 1.0, places=2)

    def test_prior_is_ignored_once_exhausted(self):
        got = burndown.compute("claude", "week", payload(100.0), now=NOW, tz=TZ,
                               rows=[], prior_pct_per_day=20.0)
        self.assertEqual(got["status"], burndown.STATUS_EXHAUSTED)
        self.assertIsNone(got["exhausts_at"])


class ExhaustedTests(unittest.TestCase):
    """A spent pool is a fact to wait out, not an alarm to raise."""

    def test_zero_remaining_is_exhausted_not_ahead(self):
        got = burndown.compute("claude", "week", payload(100.0),
                               now=NOW, tz=TZ, rows=rows(20.0, 0.0))
        self.assertTrue(got["exhausted"])
        self.assertEqual(got["status"], burndown.STATUS_EXHAUSTED)
        self.assertEqual(got["remaining_pct"], 0.0)

    def test_exhausted_makes_no_forecast(self):
        got = burndown.compute("claude", "week", payload(100.0),
                               now=NOW, tz=TZ, rows=rows(20.0, 0.0))
        self.assertIsNone(got["exhausts_at"])
        self.assertIsNone(got["exhausts_in_s"])
        self.assertFalse(got["exhausts_before_reset"])
        self.assertEqual(got["projected"], [])

    def test_exhausted_headline_states_the_reset(self):
        got = burndown.compute("claude", "week", payload(100.0),
                               now=NOW, tz=TZ, rows=rows(20.0, 0.0))
        self.assertEqual(got["headline"], "Exhausted. Resets in 3d.")

    def test_healthy_pool_is_not_exhausted(self):
        got = burndown.compute("claude", "week", payload(60.0),
                               now=NOW, tz=TZ, rows=rows(60.0, 40.0))
        self.assertFalse(got["exhausted"])


class AggregateTests(unittest.TestCase):
    def test_compute_all_skips_sources_that_are_not_ok(self):
        state = {"claude": dict(payload(60.0), ok=False)}
        self.assertEqual(burndown.compute_all(state, now=NOW, tz=TZ), {})

    def test_compute_all_groups_by_provider_and_pool(self):
        state = {"claude": payload(60.0)}
        got = burndown.compute_all(state, now=NOW, tz=TZ)
        self.assertEqual(list(got), ["claude"])
        self.assertEqual(list(got["claude"]), ["week"])

    def test_primary_prefers_critical(self):
        critical = burndown.compute("claude", "week", payload(60.0),
                                    now=NOW, tz=TZ, rows=rows(60.0, 40.0))
        healthy = burndown.compute("claude", "week", payload(45.0),
                                   now=NOW, tz=TZ, rows=rows(60.0, 55.0))
        got = burndown.primary({"claude": {"week": healthy},
                                "codex": {"week": critical}})
        self.assertEqual(got["status"], burndown.STATUS_CRITICAL)

    def test_primary_of_nothing_is_none(self):
        self.assertIsNone(burndown.primary({}))

    def test_primary_prefers_about_to_run_out_over_already_out(self):
        # Nothing to decide about a spent pool; a critical one is still a call.
        critical = burndown.compute("claude", "week", payload(60.0),
                                    now=NOW, tz=TZ, rows=rows(60.0, 40.0))
        spent = burndown.compute("codex", "week", payload(100.0),
                                 now=NOW, tz=TZ, rows=rows(20.0, 0.0))
        got = burndown.primary({"codex": {"week": spent},
                                "claude": {"week": critical}})
        self.assertEqual(got["status"], burndown.STATUS_CRITICAL)

    def test_primary_prefers_exhausted_over_healthy(self):
        healthy = burndown.compute("claude", "week", payload(45.0),
                                   now=NOW, tz=TZ, rows=rows(60.0, 55.0))
        spent = burndown.compute("codex", "week", payload(100.0),
                                 now=NOW, tz=TZ, rows=rows(20.0, 0.0))
        got = burndown.primary({"claude": {"week": healthy},
                                "codex": {"week": spent}})
        self.assertEqual(got["status"], burndown.STATUS_EXHAUSTED)


if __name__ == "__main__":
    unittest.main()
