import unittest
from unittest.mock import patch

import supabase_usage


def _lint(name="rls_disabled_in_public", level="ERROR", entity="public.posts"):
    return {
        "name": name,
        "title": name.replace("_", " ").title(),
        "level": level,
        "categories": ["SECURITY"],
        "detail": f"{entity} is exposed.",
        "remediation": "https://supabase.com/docs/guides/database/database-linter",
        "metadata": {"schema": "public", "name": entity.split(".")[-1],
                     "entity": entity, "type": "table"},
    }


class SupabaseUsageTests(unittest.TestCase):
    def setUp(self):
        supabase_usage._cache.update(t=0.0, data=None)
        supabase_usage._advisor_cache.clear()

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

    def test_flatten_keeps_management_api_metadata(self):
        row = supabase_usage._flatten_project(
            {
                "ref": "abcd1234abcdefghij",
                "name": "prod",
                "organization_id": "acme",
                "region": "eu-central-1",
                "status": "ACTIVE_HEALTHY",
                "created_at": "2024-03-29T16:32:59Z",
                "database": {
                    "host": "db.abcd1234abcdefghij.supabase.co",
                    "version": "15.8.1.034",
                    "postgres_engine": "15",
                    "release_channel": "ga",
                },
            },
            [{"name": "db", "status": "healthy", "healthy": True}],
            None,
            [],
            None,
        )

        self.assertEqual(row["created_at"], "2024-03-29T16:32:59Z")
        self.assertEqual(row["organization_id"], "acme")
        self.assertEqual(row["database"]["host"],
                         "db.abcd1234abcdefghij.supabase.co")
        self.assertEqual(row["database"]["postgres_engine"], "15")
        self.assertEqual(row["database"]["release_channel"], "ga")

    @patch("supabase_usage._project_advisors", return_value=([], None))
    @patch("supabase_usage._project_health")
    @patch("supabase_usage._get")
    @patch("supabase_usage._token", return_value="secret")
    def test_ranks_unhealthy_projects_first(self, _token, get, health, _adv):
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

    def test_lint_rows_keep_unknown_names_and_sort_worst_first(self):
        rows = supabase_usage._lint_rows({"lints": [
            _lint("unused_index", "INFO", "public.old_idx"),
            _lint("sensitive_columns_exposed", "ERROR", "public.users"),
            _lint("future_lint_nobody_has_seen", "SOMETHING_NEW"),
        ]})

        self.assertEqual([row["level"] for row in rows],
                         ["ERROR", "WARN", "INFO"])
        # An unknown severity must not vanish — it lands in WARN.
        self.assertIn("future_lint_nobody_has_seen",
                      [row["name"] for row in rows])
        self.assertEqual(rows[0]["entity"], "public.users")

    def test_lint_entity_falls_back_to_schema_and_name(self):
        rows = supabase_usage._lint_rows({"lints": [{
            "name": "rls_disabled_in_public",
            "level": "ERROR",
            "metadata": {"schema": "public", "name": "posts"},
        }]})

        self.assertEqual(rows[0]["entity"], "public.posts")

    @patch("supabase_usage._project_health", return_value=([], None))
    @patch("supabase_usage._get")
    @patch("supabase_usage._token", return_value="secret")
    def test_security_counts_roll_up_without_touching_health(
            self, _token, get, _health):
        def responses(path, *args, **kwargs):
            if path == "/v1/projects":
                return [{"ref": "a", "name": "App",
                         "status": "ACTIVE_HEALTHY"}]
            return {"lints": [_lint(), _lint("unused_index", "INFO"),
                              _lint("auth_otp_long_expiry", "WARN")]}

        get.side_effect = responses

        result = supabase_usage.fetch_projects(force=True)
        project = result["projects"][0]

        # Lints are not health: the project is still up, and still healthy.
        self.assertTrue(project["healthy"])
        self.assertEqual(result["alert_count"], 0)
        self.assertEqual(result["lint_error_count"], 1)
        self.assertEqual(result["lint_warn_count"], 1)
        self.assertEqual(result["lint_total"], 3)
        self.assertEqual(project["lint_info_count"], 1)
        self.assertFalse(project["lint_truncated"])

    @patch("supabase_usage._get")
    def test_advisor_failure_is_soft_and_keeps_the_last_good_answer(self, get):
        project = {"ref": "a"}
        get.return_value = {"lints": [_lint()]}
        lints, error = supabase_usage._project_advisors(project, "secret")
        self.assertEqual(len(lints), 1)
        self.assertIsNone(error)

        get.side_effect = OSError("connection reset")
        lints, error = supabase_usage._project_advisors(
            project, "secret", force=True)

        # A blip must not read as "all clear".
        self.assertEqual(len(lints), 1)
        self.assertIn("connection reset", error)

    @patch("supabase_usage._get")
    def test_advisors_are_cached_apart_from_the_health_poll(self, get):
        get.return_value = {"lints": [_lint()]}
        project = {"ref": "a"}

        supabase_usage._project_advisors(project, "secret")
        supabase_usage._project_advisors(project, "secret")

        self.assertEqual(get.call_count, 1)


if __name__ == "__main__":
    unittest.main()
