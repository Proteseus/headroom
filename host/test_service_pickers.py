"""Settings pickers: available GitHub remotes and Vercel teams."""

from __future__ import annotations

import os
import tempfile
import unittest
from unittest import mock

import app_config
import github_actions as ga
import vercel_builds


class DiscoverableReposTests(unittest.TestCase):
    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.root = self._tmpdir.name
        self._cfg = tempfile.NamedTemporaryFile("w+", delete=False)
        self._cfg.write("{}")
        self._cfg.flush()
        self._store = app_config.STORE_PATH
        app_config.STORE_PATH = self._cfg.name
        app_config.reload()

    def tearDown(self):
        app_config.STORE_PATH = self._store
        app_config.reload()
        self._cfg.close()
        os.unlink(self._cfg.name)
        self._tmpdir.cleanup()

    def _repo(self, name, slug):
        path = os.path.join(self.root, name)
        os.makedirs(os.path.join(path, ".git"))
        return path, slug

    def test_lists_remotes_without_owner_filter(self):
        path_a, slug_a = self._repo("alpha", "acme/alpha")
        path_b, slug_b = self._repo("beta", "other/beta")
        app_config.set_git_config(root=self.root)
        app_config.set_github_watch(prefixes=["acme/"], max_discovered=1)

        def remote(p):
            if p == path_a:
                return slug_a
            if p == path_b:
                return slug_b
            return None

        with mock.patch.object(ga, "_remote_slug", side_effect=remote):
            available = ga.discoverable_repos()
            watching = ga._discover_org_repos()

        # Newest mtime first; both remotes appear regardless of owner filter.
        self.assertCountEqual(available, [slug_a, slug_b])
        self.assertEqual(set(available), {slug_a, slug_b})
        # Owner filter + cap still apply to the poll path.
        self.assertEqual(watching, [slug_a])

    def test_includes_always_watch_not_on_disk(self):
        app_config.set_git_config(root=self.root)
        app_config.set_github_watch(always_repos=["remote/only"])
        with mock.patch.object(ga, "_remote_slug", return_value=None):
            available = ga.discoverable_repos()
        self.assertEqual(available, ["remote/only"])


class AvailableTeamsTests(unittest.TestCase):
    def test_empty_when_signed_out(self):
        with mock.patch.object(vercel_builds, "_cli_json", return_value={}):
            self.assertEqual(vercel_builds.available_teams(), [])

    def test_lists_slug_and_name(self):
        auth = {"token": "tok", "expiresAt": 9_999_999_999}
        teams = [
            {"slug": "acme", "name": "Acme Inc"},
            {"slug": "ada", "name": "ada"},
            {"slug": "acme", "name": "dup"},
            {"name": "no-slug"},
        ]
        with mock.patch.object(vercel_builds, "_cli_json", return_value=auth), \
             mock.patch.object(vercel_builds, "_token_fresh", return_value=True), \
             mock.patch.object(vercel_builds, "_list_teams", return_value=teams):
            out = vercel_builds.available_teams()
        self.assertEqual(out, [
            {"slug": "acme", "name": "Acme Inc"},
            {"slug": "ada", "name": "ada"},
        ])


if __name__ == "__main__":
    unittest.main()
