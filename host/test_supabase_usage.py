import unittest
from unittest.mock import patch

import supabase_usage


class SupabaseUsageTests(unittest.TestCase):
    def setUp(self):
        supabase_usage._cache.update(t=0.0, data=None)

    @patch("supabase_usage._token", return_value=None)
    def test_missing_token_is_safe_and_actionable(self, _token):
        result = supabase_usage.fetch_projects(force=True)

        self.assertFalse(result["configured"])
        self.assertEqual(result["projects"], [])
        self.assertIn("Settings", result["error"])

    def test_normalizes_health_services(self):
        rows = supabase_usage._service_rows({
            "services": [
                {"name": "auth", "status": "healthy"},
                {"name": "storage", "status": "unhealthy"},
            ]
        })

        self.assertTrue(rows[0]["healthy"])
        self.assertFalse(rows[1]["healthy"])

    @patch("supabase_usage._project_health")
    @patch("supabase_usage._get")
    @patch("supabase_usage._token", return_value="secret")
    def test_ranks_unhealthy_projects_first(self, _token, get, health):
        get.return_value = [
            {"ref": "ok", "name": "Healthy", "status": "ACTIVE_HEALTHY"},
            {"ref": "bad", "name": "Broken", "status": "ACTIVE_HEALTHY"},
        ]
        health.side_effect = [
            ([{"name": "auth", "status": "healthy", "healthy": True}], None),
            ([{"name": "db", "status": "unhealthy", "healthy": False}], None),
        ]

        result = supabase_usage.fetch_projects(force=True)

        self.assertTrue(result["ok"])
        self.assertEqual(result["alert_count"], 1)
        self.assertEqual(result["projects"][0]["ref"], "bad")


if __name__ == "__main__":
    unittest.main()
