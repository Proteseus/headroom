import unittest
from unittest.mock import patch

import plausible_usage


class PlausibleUsageTests(unittest.TestCase):
    def setUp(self):
        plausible_usage._cache.update(t=0.0, data=None)

    @patch("plausible_usage._token", return_value=None)
    def test_missing_token_is_safe_and_actionable(self, _token):
        result = plausible_usage.fetch_stats(force=True)

        self.assertFalse(result["configured"])
        self.assertEqual(result["sites"], [])
        self.assertIn("Settings", result["error"])

    @patch("plausible_usage._list_sites", return_value=([], "no list"))
    @patch("plausible_usage._configured_sites", return_value=[])
    @patch("plausible_usage._token", return_value="secret")
    def test_missing_sites_surfaces_list_error(self, _token, _sites, _list):
        result = plausible_usage.fetch_stats(force=True)

        self.assertTrue(result["configured"])
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "no list")

    @patch("plausible_usage._fetch_site")
    @patch("plausible_usage._list_sites", return_value=(["b.dev", "a.dev"], None))
    @patch("plausible_usage._configured_sites", return_value=[])
    @patch("app_config.plausible_range", return_value="24h")
    @patch("plausible_usage._token", return_value="secret")
    def test_discovers_sites_from_api(
            self, _token, _range, _config, _list, fetch_site):
        fetch_site.side_effect = [
            {
                "domain": "b.dev",
                "range": "24h",
                "range_label": "24h",
                "visitors_today": 5,
                "pageviews_today": 8,
                "visitors_7d": 50,
                "pageviews_7d": 80,
                "bounce_rate_7d": 55,
                "visit_duration_7d": 60,
                "realtime": 3,
                "dashboard_url": "https://plausible.io/b.dev",
                "error": None,
            },
            {
                "domain": "a.dev",
                "range": "24h",
                "range_label": "24h",
                "visitors_today": 10,
                "pageviews_today": 20,
                "visitors_7d": 100,
                "pageviews_7d": 200,
                "bounce_rate_7d": 40,
                "visit_duration_7d": 90,
                "realtime": 0,
                "dashboard_url": "https://plausible.io/a.dev",
                "error": None,
            },
        ]

        result = plausible_usage.fetch_stats(force=True)

        self.assertTrue(result["ok"])
        self.assertEqual(result["sites_source"], "api")
        self.assertEqual(result["range"], "24h")
        self.assertEqual(result["sites"][0]["domain"], "b.dev")
        self.assertEqual(fetch_site.call_args_list[0].args[2], "24h")

    @patch("plausible_usage._query")
    @patch("plausible_usage._realtime", return_value=1)
    def test_fetch_site_uses_configured_range(self, _realtime, query):
        query.side_effect = [
            {"visitors": 9, "pageviews": 12},
            {"visitors": 40, "pageviews": 80, "bounce_rate": 50, "visit_duration": 60},
        ]
        row = plausible_usage._fetch_site("secret", "a.dev", "24h")
        self.assertEqual(row["visitors_today"], 9)
        self.assertEqual(row["range"], "24h")
        self.assertEqual(query.call_args_list[0].args[3], "24h")
        self.assertEqual(query.call_args_list[1].args[3], "7d")

    @patch("plausible_usage._list_sites", return_value=(["a.dev", "b.dev", "c.dev"], None))
    @patch("plausible_usage._configured_sites", return_value=["b.dev"])
    def test_config_filters_api_list(self, _config, _list):
        sites, source = plausible_usage._resolve_sites("secret")
        self.assertEqual(sites, ["b.dev"])
        self.assertEqual(source, "api+filter")

    @patch("plausible_usage._list_sites", return_value=([], "denied"))
    @patch("plausible_usage._configured_sites", return_value=["a.dev"])
    def test_config_falls_back_when_list_fails(self, _config, _list):
        sites, source = plausible_usage._resolve_sites("secret")
        self.assertEqual(sites, ["a.dev"])
        self.assertEqual(source, "config")

    @patch("plausible_usage._request")
    def test_list_sites_paginates(self, request):
        request.side_effect = [
            {
                "sites": [{"domain": "a.dev"}],
                "meta": {"after": "cursor1", "before": None, "limit": 100},
            },
            {
                "sites": [{"domain": "b.dev"}],
                "meta": {"after": None, "before": "cursor1", "limit": 100},
            },
        ]
        sites, error = plausible_usage._list_sites("secret")
        self.assertIsNone(error)
        self.assertEqual(sites, ["a.dev", "b.dev"])
        self.assertEqual(request.call_count, 2)

    def test_metric_map_aligns_with_query_order(self):
        mapped = plausible_usage._metric_map(
            {"results": [{"metrics": [12, 34], "dimensions": []}]},
            ("visitors", "pageviews"),
        )
        self.assertEqual(mapped["visitors"], 12)
        self.assertEqual(mapped["pageviews"], 34)


if __name__ == "__main__":
    unittest.main()
