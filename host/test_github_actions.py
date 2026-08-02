import time
import unittest
from unittest import mock

import github_actions as ga


class OwnerPrefixTests(unittest.TestCase):
    def test_no_prefixes_watches_everything(self):
        self.assertTrue(ga._matches_owner("acme/app", ()))

    def test_any_configured_owner_matches(self):
        prefixes = ("acme/", "ada/")
        self.assertTrue(ga._matches_owner("acme/app", prefixes))
        self.assertTrue(ga._matches_owner("ada/side-project", prefixes))
        self.assertFalse(ga._matches_owner("someone-else/app", prefixes))

    def test_owner_case_does_not_decide(self):
        # Remotes keep whatever case was typed; GitHub owners don't care.
        self.assertTrue(ga._matches_owner("Acme/App", ("acme/",)))


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


class InboxTests(unittest.TestCase):
    def test_empty_without_watched_repos(self):
        self.assertEqual(ga.fetch_inbox("tok", []), [])

    def test_filters_to_watched_repos_and_dedupes(self):
        user = {"login": "mz"}
        review = {
            "total_count": 1,
            "items": [{
                "id": 11,
                "number": 7,
                "title": "Review me",
                "html_url": "https://github.com/acme/web/pull/7",
                "repository_url": "https://api.github.com/repos/acme/web",
                "pull_request": {},
                "user": {"login": "alice"},
                "updated_at": "2026-08-01T12:00:00Z",
            }],
        }
        assigned = {
            "total_count": 2,
            "items": [
                {
                    "id": 11,
                    "number": 7,
                    "title": "Review me",
                    "html_url": "https://github.com/acme/web/pull/7",
                    "repository_url": "https://api.github.com/repos/acme/web",
                    "pull_request": {},
                    "user": {"login": "alice"},
                    "updated_at": "2026-08-01T12:00:00Z",
                },
                {
                    "id": 22,
                    "number": 3,
                    "title": "Fix lint",
                    "html_url": "https://github.com/other/skip/issues/3",
                    "repository_url": "https://api.github.com/repos/other/skip",
                    "user": {"login": "bob"},
                    "updated_at": "2026-08-01T11:00:00Z",
                },
            ],
        }
        mentions = {
            "total_count": 2,
            "items": [
                {
                    # Same PR also @mentions you — review_request must win.
                    "id": 11,
                    "number": 7,
                    "title": "Review me",
                    "html_url": "https://github.com/acme/web/pull/7",
                    "repository_url": "https://api.github.com/repos/acme/web",
                    "pull_request": {},
                    "user": {"login": "alice"},
                    "updated_at": "2026-08-01T13:00:00Z",
                },
                {
                    "id": 33,
                    "number": 9,
                    "title": "Hey @mz",
                    "html_url": "https://github.com/acme/web/issues/9",
                    "repository_url": "https://api.github.com/repos/acme/web",
                    "user": {"login": "carol"},
                    "updated_at": "2026-08-01T10:00:00Z",
                },
            ],
        }

        def fake_get(path, token, query=None, timeout=12):
            if path == "/user":
                return user
            q = (query or {}).get("q") or ""
            if "review-requested" in q:
                return review
            if "assignee:" in q:
                return assigned
            if "mentions:" in q:
                return mentions
            raise AssertionError(q)

        with mock.patch.object(ga, "_get", side_effect=fake_get):
            rows = ga.fetch_inbox("tok", ["acme/web"])
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["reason"], "review_request")
        self.assertEqual(rows[0]["repo"], "acme/web")
        self.assertEqual(rows[0]["author"], "alice")
        self.assertEqual(rows[0]["number"], 7)
        self.assertEqual(rows[1]["reason"], "mention")
        self.assertEqual(rows[1]["number"], 9)

    def test_attention_summary_names_a_single_repo(self):
        summary = ga.attention_inbox_summary([{
            "reason": "review_request",
            "repo": "acme/web",
            "title": "x",
        }])
        self.assertEqual(summary, "web · review requested")

    def test_attention_summary_names_a_mention(self):
        summary = ga.attention_inbox_summary([{
            "reason": "mention",
            "repo": "acme/web",
            "title": "x",
            "is_pr": False,
        }])
        self.assertEqual(summary, "web · mentioned on issue")

    def test_attention_summary_counts_mixed(self):
        summary = ga.attention_inbox_summary([
            {"reason": "review_request", "repo": "acme/web"},
            {"reason": "mention", "repo": "acme/api"},
            {"reason": "mention", "repo": "acme/web"},
        ])
        self.assertEqual(summary, "1 review request · 2 mentions")


if __name__ == "__main__":
    unittest.main()
