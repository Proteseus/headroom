import time
import unittest

import github_actions as ga


class AttentionFreshnessTests(unittest.TestCase):
    def test_fresh_failure_counts(self):
        now = time.time()
        rows = [{
            "status": "failure",
            "repo": "acme/app",
            "sha": "abc",
            "created_at": now - 60,
        }]
        self.assertEqual(ga.attention_fail_count(rows, now=now), 1)

    def test_old_failure_ignored(self):
        now = time.time()
        rows = [{
            "status": "failure",
            "repo": "acme/app",
            "sha": "abc",
            "created_at": now - (ga.ATTENTION_FAIL_MAX_AGE_S + 10),
        }]
        self.assertEqual(ga.attention_fail_count(rows, now=now), 0)

    def test_missing_timestamp_counts_as_fresh(self):
        rows = [{
            "status": "failure",
            "repo": "acme/app",
            "sha": "abc",
            "created_at": None,
        }]
        self.assertEqual(ga.attention_fail_count(rows), 1)

    def test_clusters_same_sha(self):
        now = time.time()
        rows = [
            {
                "status": "failure",
                "repo": "acme/app",
                "sha": "abc",
                "name": "CI",
                "created_at": now - 60,
            },
            {
                "status": "failure",
                "repo": "acme/app",
                "sha": "abc",
                "name": "Lint",
                "created_at": now - 90,
            },
        ]
        self.assertEqual(ga.attention_fail_count(rows, now=now), 1)

    def test_running_does_not_inflate_fail_count(self):
        now = time.time()
        rows = [{
            "status": "running",
            "repo": "acme/app",
            "sha": "abc",
            "created_at": now,
        }]
        self.assertEqual(ga.attention_fail_count(rows, now=now), 0)


if __name__ == "__main__":
    unittest.main()
