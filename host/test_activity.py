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


if __name__ == "__main__":
    unittest.main()
