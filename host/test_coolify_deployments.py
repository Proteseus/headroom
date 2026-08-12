import os
import time
import unittest
import urllib.error
from unittest import mock

import coolify_deployments as coolify


class CoolifyDeploymentsTests(unittest.TestCase):
    def setUp(self):
        coolify._cache.clear()
        coolify._cache.update(t=0.0, data=None)
        self.env = mock.patch.dict(os.environ, {
            "HEADROOM_COOLIFY_URL": "https://server.example.com/",
            "HEADROOM_COOLIFY_TOKEN": "secret",
        }, clear=False)
        self.env.start()

    def tearDown(self):
        self.env.stop()

    def test_base_url_accepts_api_suffix(self):
        with mock.patch.dict(os.environ, {
            "HEADROOM_COOLIFY_URL": "https://server.example.com/api/v1/",
        }):
            self.assertEqual(coolify._base_url(), "https://server.example.com")

    def test_fetches_live_work_and_latest_fresh_failure(self):
        now = time.time()

        def fake_get(path, token, query=None, timeout=15):
            self.assertEqual(token, "secret")
            if path == "/deployments":
                return [{
                    "deployment_uuid": "live-1",
                    "application_id": 7,
                    "application_name": "website",
                    "server_name": "primary",
                    "status": "in_progress",
                    "commit": "abcdef123456",
                    "created_at": now - 120,
                }]
            if path == "/applications":
                return [
                    {"id": 7, "uuid": "app-live", "name": "website"},
                    {"id": 8, "uuid": "app-failed", "name": "worker"},
                ]
            if path.endswith("app-live"):
                return [{
                    "deployment_uuid": "live-1",
                    "status": "in_progress",
                    "created_at": now - 120,
                }]
            if path.endswith("app-failed"):
                return [{
                    "deployment_uuid": "fail-1",
                    "status": "failed",
                    "commit": "123456789",
                    "created_at": now - 600,
                }]
            raise AssertionError(path)

        with mock.patch.object(coolify, "_get", side_effect=fake_get):
            payload = coolify.fetch_deployments(force=True)

        self.assertTrue(payload["ok"])
        self.assertEqual(payload["active_count"], 1)
        self.assertEqual(payload["active"][0]["status_label"], "Building")
        self.assertEqual(payload["active"][0]["short_commit"], "abcdef1")
        self.assertEqual(payload["failure_count"], 1)
        self.assertEqual(payload["failures"][0]["application_name"], "worker")

    def test_newer_success_replaces_failure(self):
        with mock.patch.object(coolify, "_get") as get:
            get.side_effect = [
                [],
                [{"uuid": "app", "name": "website"}],
                [{"deployment_uuid": "done", "status": "finished",
                  "created_at": time.time()}],
            ]
            payload = coolify.fetch_deployments(force=True)
        self.assertEqual(payload["failures"], [])
        self.assertEqual(payload["failure_count"], 0)

    def test_active_retry_does_not_hide_previous_failure(self):
        now = time.time()
        with mock.patch.object(coolify, "_get") as get:
            get.side_effect = [
                [{"deployment_uuid": "retry", "application_id": 1,
                  "status": "in_progress", "created_at": now}],
                [{"id": 1, "uuid": "app", "name": "website"}],
                [
                    {"deployment_uuid": "retry", "status": "in_progress",
                     "created_at": now},
                    {"deployment_uuid": "failed", "status": "failed",
                     "created_at": now - 300},
                ],
            ]
            payload = coolify.fetch_deployments(force=True)
        self.assertEqual(payload["active_count"], 1)
        self.assertEqual(payload["failures"][0]["id"], "failed")

    def test_old_failure_ages_out(self):
        old = time.time() - coolify.FAILURE_MAX_AGE_S - 1
        with mock.patch.object(coolify, "_get") as get:
            get.side_effect = [
                [],
                [{"uuid": "app", "name": "website"}],
                [{"deployment_uuid": "old", "status": "failed",
                  "created_at": old}],
            ]
            payload = coolify.fetch_deployments(force=True)
        self.assertEqual(payload["failures"], [])

    def test_missing_token_is_explicit_and_never_calls_network(self):
        with mock.patch.dict(os.environ, {
            "HEADROOM_COOLIFY_TOKEN": "",
            "COOLIFY_API_TOKEN": "",
        }), mock.patch.object(coolify, "_get") as get:
            payload = coolify.fetch_deployments(force=True)
        # A previous good reading may be replayed stale; the actionable auth
        # marker and error must still replace a false "healthy" impression.
        self.assertTrue(payload["auth_required"])
        self.assertIn("token", payload["error"])
        get.assert_not_called()

    def test_rejected_token_sets_auth_required(self):
        error = urllib.error.HTTPError(
            "https://server.example.com/api/v1/deployments",
            401, "Unauthorized", {}, None)
        with mock.patch.object(coolify, "_get", side_effect=error):
            payload = coolify.fetch_deployments(force=True)
        self.assertTrue(payload["auth_required"])
        self.assertTrue(payload["configured"])
        self.assertEqual(payload["error"], "Coolify token rejected")

    def test_failure_count_includes_rows_beyond_display_cap(self):
        now = time.time()
        apps = [{"uuid": f"app-{i}", "name": f"app-{i}"}
                for i in range(coolify.MAX_FAILURES + 2)]

        def fake_get(path, token, query=None, timeout=15):
            if path == "/deployments":
                return []
            if path == "/applications":
                return apps
            return [{"deployment_uuid": path.rsplit("/", 1)[-1],
                     "status": "failed", "created_at": now}]

        with mock.patch.object(coolify, "_get", side_effect=fake_get):
            payload = coolify.fetch_deployments(force=True)
        self.assertEqual(len(payload["failures"]), coolify.MAX_FAILURES)
        self.assertEqual(payload["failure_count"], coolify.MAX_FAILURES + 2)


if __name__ == "__main__":
    unittest.main()
