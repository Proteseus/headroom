import unittest
from datetime import date

import activity_history


class ActivityHistoryTests(unittest.TestCase):
    def test_merges_claude_and_quota_sources_without_mixing_units(self):
        result = activity_history.build(
            [
                {
                    "date": "2026-08-01",
                    "active_minutes": 20,
                    "sessions": 2,
                    "total": 1000,
                    "cost_usd": 0.25,
                },
            ],
            [
                {
                    "date": "2026-08-01",
                    "burns": {"codex": 4.5, "cursor": 0},
                },
            ],
            today=date(2026, 8, 2),
            days=2,
            available_sources=("claude", "codex", "cursor"),
        )

        day = result["days"][0]
        self.assertEqual(day["sources"], ["claude", "codex"])
        self.assertEqual(day["level"], 2)
        self.assertEqual(day["active_minutes"], 20)
        self.assertEqual(day["burns"], {"codex": 4.5})
        self.assertEqual(result["levels"], [2, 0])
        self.assertEqual(result["active_days"], 1)
        self.assertEqual(result["current_streak"], 0)

    def test_multiple_non_claude_sources_add_intensity(self):
        result = activity_history.build(
            [],
            [{
                "date": "2026-08-02",
                "burns": {"codex": 1, "cursor": 1, "gemini": 1},
            }],
            today=date(2026, 8, 2),
            days=1,
        )
        self.assertEqual(result["days"][0]["level"], 3)
        self.assertEqual(result["current_streak"], 1)

    def test_empty_days_are_kept_in_levels_but_not_sparse_details(self):
        result = activity_history.build(
            [], [], today=date(2026, 8, 2), days=3)
        self.assertEqual(result["levels"], [0, 0, 0])
        self.assertEqual(result["days"], [])
        self.assertIsNone(result["best_day"])


if __name__ == "__main__":
    unittest.main()
