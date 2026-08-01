import unittest

import headroom_server
import vercel_builds


class ActivityTests(unittest.TestCase):
    def test_flattens_vercel_git_and_error_metadata(self):
        row = vercel_builds._flatten({
            "uid": "dpl_1",
            "name": "store-web",
            "readyState": "ERROR",
            "target": "production",
            "created": 1_700_000_000_000,
            "errorMessage": "Build command failed",
            "inspectorUrl": "https://vercel.com/inspect",
            "url": "store.example.vercel.app",
            "meta": {
                "githubCommitSha": "abcdef123456",
                "githubCommitRepo": "store",
                "githubCommitRef": "main",
                "githubCommitMessage": "Fix checkout",
            },
        })

        self.assertEqual(row["id"], "dpl_1")
        self.assertEqual(row["sha"], "abcdef123456")
        self.assertEqual(row["short_sha"], "abcdef1")
        self.assertEqual(row["commit_message"], "Fix checkout")
        self.assertEqual(row["error_message"], "Build command failed")

    def test_merges_deployed_commit_without_duplicate(self):
        deployment = {
            "id": "dpl_1",
            "status": "ready",
            "project": "store-web",
            "repo": "store",
            "branch": "main",
            "sha": "abc",
            "short_sha": "abc",
            "commit_message": "Ship it",
            "target": "production",
            "created_at": 2000,
            "ago": "1m",
        }
        commits = [
            {
                "sha": "abc",
                "short_sha": "abc",
                "repo": "store",
                "subject": "Ship it",
                "created_at": 1900,
                "pushed": True,
            },
            {
                "sha": "def",
                "short_sha": "def",
                "repo": "api",
                "subject": "Local work",
                "created_at": 1800,
                "pushed": False,
            },
        ]

        items = headroom_server._build_activity(
            {"deployments": [deployment]}, {"commits": commits})

        self.assertEqual(len(items), 2)
        self.assertEqual(items[0]["status"], "ready")
        self.assertEqual(items[1]["status"], "local")

    def test_adds_unhealthy_supabase_project_to_activity(self):
        items = headroom_server._build_activity({}, {}, {
            "updated_at": 2000,
            "projects": [{
                "ref": "project-ref",
                "name": "Production DB",
                "healthy": False,
                "unhealthy_services": ["auth", "storage"],
                "dashboard_url": "https://supabase.com/dashboard/project/project-ref",
            }],
        })

        self.assertEqual(items[0]["kind"], "supabase")
        self.assertEqual(items[0]["status"], "error")
        self.assertIn("auth", items[0]["error_message"])

    def test_pins_failing_actions_above_newer_commits(self):
        import time
        now = time.time()
        commits = [{
            "sha": "new",
            "short_sha": "new",
            "repo": "headroom",
            "subject": "fresh commit",
            "created_at": now,
            "pushed": True,
        }]
        github = {
            "runs": [{
                "id": "1",
                "status": "failure",
                "name": "CI",
                "display_title": "fresh fail",
                "repo": "acme/app",
                "created_at": now - 600,
                "ago": "10m",
                "url": "https://github.com/acme/app/actions/runs/1",
            }],
        }
        items = headroom_server._build_activity(
            {}, {"commits": commits}, github=github)
        self.assertEqual(items[0]["kind"], "github")
        self.assertEqual(items[0]["status"], "failure")
        self.assertEqual(items[1]["kind"], "commit")

    def test_omits_stale_action_failures(self):
        import time
        now = time.time()
        commits = [{
            "sha": "new",
            "short_sha": "new",
            "repo": "headroom",
            "subject": "fresh commit",
            "created_at": now,
            "pushed": True,
        }]
        github = {
            "runs": [{
                "id": "1",
                "status": "failure",
                "name": "CI",
                "display_title": "ancient fail",
                "repo": "acme/app",
                "created_at": now - (100 * 86400),
                "ago": "100d",
                "url": "https://github.com/acme/app/actions/runs/1",
            }],
        }
        items = headroom_server._build_activity(
            {}, {"commits": commits}, github=github)
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["kind"], "commit")

    def test_inbox_rows_carry_author_and_number(self):
        items = headroom_server._build_activity({}, {}, github={
            "inbox": [{
                "id": "pr_1",
                "reason": "review_request",
                "repo": "acme/web",
                "number": 42,
                "title": "Tighten the menu bar glyph",
                "author": "alice",
                "url": "https://github.com/acme/web/pull/42",
                "ago": "12m",
                "created_at": 1_700_000_000,
            }],
        })
        self.assertEqual(len(items), 1)
        row = items[0]
        self.assertEqual(row["id"], "github-inbox:pr_1")
        self.assertEqual(row["status"], "review_request")
        self.assertEqual(row["author"], "alice")
        self.assertEqual(row["number"], 42)
        self.assertEqual(row["repo"], "acme/web")


if __name__ == "__main__":
    unittest.main()
