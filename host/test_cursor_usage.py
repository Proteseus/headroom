import unittest

import cursor_usage


class CursorUsageParsingTests(unittest.TestCase):
    def test_prefers_direct_total_percent(self):
        result = cursor_usage.parse_usage({
            "planUsage": {
                "totalPercentUsed": 4,
                "autoPercentUsed": 0,
                "apiPercentUsed": 34,
            }
        })

        self.assertEqual(result["total"]["pct"], 4)
        self.assertEqual(result["auto"]["pct"], 0)
        self.assertEqual(result["api"]["pct"], 34)

    def test_falls_back_to_lane_average(self):
        result = cursor_usage.parse_usage({
            "planUsage": {
                "autoPercentUsed": 12.5,
                "apiPercentUsed": 3,
            }
        })

        self.assertEqual(result["total"]["pct"], 7.8)

    def test_falls_back_to_used_limit_ratio(self):
        result = cursor_usage.parse_usage({
            "planUsage": {"used": 86, "limit": 2000}
        })

        self.assertEqual(result["total"]["pct"], 4.3)


if __name__ == "__main__":
    unittest.main()

