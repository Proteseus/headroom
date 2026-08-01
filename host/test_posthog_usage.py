import unittest
from unittest.mock import patch

import posthog_usage


class PostHogUsageTests(unittest.TestCase):
    def setUp(self):
        posthog_usage._cache.update(t=0.0, data=None)

    @patch("posthog_usage._token", return_value=None)
    def test_missing_token_is_safe_and_actionable(self, _token):
        result = posthog_usage.fetch_stats(force=True)

        self.assertFalse(result["configured"])
        self.assertEqual(result["projects"], [])
        self.assertIn("Settings", result["error"])

    @patch("posthog_usage._list_projects", return_value=([], "no list"))
    @patch("posthog_usage._configured_projects", return_value=[])
    @patch("posthog_usage._token", return_value="secret")
    def test_missing_projects_surfaces_list_error(self, _token, _config, _list):
        result = posthog_usage.fetch_stats(force=True)

        self.assertTrue(result["configured"])
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "no list")

    @patch("posthog_usage._fetch_project")
    @patch("posthog_usage._list_projects", return_value=([
        {"id": "2", "name": "Beta"},
        {"id": "1", "name": "Alpha"},
    ], None))
    @patch("posthog_usage._configured_projects", return_value=[])
    @patch("app_config.posthog_range", return_value="24h")
    @patch("posthog_usage._token", return_value="secret")
    def test_discovers_projects_from_api(
            self, _token, _range, _config, _list, fetch_project):
        fetch_project.side_effect = [
            {
                "id": "2",
                "name": "Beta",
                "range": "24h",
                "range_label": "24h",
                "events_today": 50,
                "users_today": 8,
                "events_7d": 500,
                "users_7d": 80,
                "realtime": 3,
                "dashboard_url": "https://us.posthog.com/project/2",
                "error": None,
            },
            {
                "id": "1",
                "name": "Alpha",
                "range": "24h",
                "range_label": "24h",
                "events_today": 100,
                "users_today": 20,
                "events_7d": 1000,
                "users_7d": 200,
                "realtime": 0,
                "dashboard_url": "https://us.posthog.com/project/1",
                "error": None,
            },
        ]

        result = posthog_usage.fetch_stats(force=True)

        self.assertTrue(result["ok"])
        self.assertEqual(result["projects_source"], "api")
        self.assertEqual(result["range"], "24h")
        self.assertEqual(result["projects"][0]["id"], "2")
        self.assertEqual(fetch_project.call_args_list[0].args[2], "24h")

    @patch("posthog_usage._query_live", return_value=1)
    @patch("posthog_usage._query_counts")
    def test_fetch_project_uses_configured_range(self, query_counts, _live):
        query_counts.side_effect = [
            (9, 4),
            (40, 18),
        ]
        row = posthog_usage._fetch_project(
            "secret", {"id": "1", "name": "Alpha"}, "24h")
        self.assertEqual(row["events_today"], 9)
        self.assertEqual(row["users_today"], 4)
        self.assertEqual(row["range"], "24h")
        self.assertIn("24 HOUR", query_counts.call_args_list[0].args[2])
        self.assertIn("7 DAY", query_counts.call_args_list[1].args[2])

    @patch("posthog_usage._list_projects", return_value=([
        {"id": "1", "name": "A"},
        {"id": "2", "name": "B"},
        {"id": "3", "name": "C"},
    ], None))
    @patch("posthog_usage._configured_projects", return_value=["2"])
    def test_config_filters_api_list(self, _config, _list):
        projects, source = posthog_usage._resolve_projects("secret")
        self.assertEqual([row["id"] for row in projects], ["2"])
        self.assertEqual(source, "api+filter")

    @patch("posthog_usage._list_projects", return_value=([], "denied"))
    @patch("posthog_usage._configured_projects", return_value=["1"])
    def test_config_falls_back_when_list_fails(self, _config, _list):
        projects, source = posthog_usage._resolve_projects("secret")
        self.assertEqual([row["id"] for row in projects], ["1"])
        self.assertEqual(source, "config")

    def test_hogql_row_reads_list_and_dict(self):
        self.assertEqual(
            posthog_usage._hogql_row({"results": [[12, 34]]}),
            (12, 34),
        )
        self.assertEqual(
            posthog_usage._hogql_row(
                {"results": [{"events": 12, "users": 34}]}),
            (12, 34),
        )


if __name__ == "__main__":
    unittest.main()
