#!/usr/bin/env python3
"""Extra logins per provider: the store, and the registry rows it grows."""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from unittest.mock import patch

import accounts
import oauth_usage
import sources_config


class AccountsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.patches = [
            patch.object(accounts, "STORE_PATH",
                         os.path.join(self.root, "accounts.json")),
            patch.object(sources_config, "STORE_PATH",
                         os.path.join(self.root, "sources.json")),
        ]
        for item in self.patches:
            item.start()
        sources_config.reload_registry()

    def tearDown(self):
        for item in self.patches:
            item.stop()
        self.tmp.cleanup()
        # Leave the module registry as this machine's real one.
        sources_config.reload_registry()

    def _claude_dir(self, name="claude-work", signed_in=True):
        path = os.path.join(self.root, name)
        os.makedirs(path, exist_ok=True)
        if signed_in:
            with open(os.path.join(path, oauth_usage.CREDS_NAME), "w") as handle:
                json.dump({"claudeAiOauth": {"accessToken": "x"}}, handle)
        return path

    def test_added_account_becomes_its_own_registry_row(self):
        account = sources_config.add_account(
            "claude", "Work", self._claude_dir())
        self.assertEqual(account.id, "claude:work")
        sources_config.reload_registry()

        row = sources_config.BY_ID["claude:work"]
        self.assertEqual(row.title, "Claude · Work")
        # Everything but identity is inherited, so the account meters and
        # charts exactly like the provider it belongs to.
        base = sources_config.BY_ID["claude"]
        self.assertEqual(row.pools, base.pools)
        self.assertEqual(row.accent, base.accent)
        self.assertEqual(row.headline, base.headline)
        self.assertIn("claude:work", sources_config.BURN_SOURCE_IDS)

    def test_account_row_sits_behind_its_provider_and_is_on(self):
        sources_config.add_account("claude", "Work", self._claude_dir())
        sources_config.reload_registry()
        order = sources_config.order_ids()
        self.assertEqual(order.index("claude:work"), order.index("claude") + 1)
        # Pointing Headroom at a second folder means wanting to see it.
        self.assertTrue(sources_config.enabled_map()["claude:work"])

    def test_default_login_keeps_the_bare_id(self):
        sources_config.add_account("claude", "Work", self._claude_dir())
        sources_config.reload_registry()
        self.assertIn("claude", sources_config.BY_ID)
        self.assertIsNone(sources_config.BY_ID["claude"].account)

    def test_removing_forgets_the_row_and_its_flag(self):
        sources_config.add_account("claude", "Work", self._claude_dir())
        sources_config.reload_registry()
        self.assertTrue(sources_config.remove_account("claude:work"))
        self.assertNotIn("claude:work", sources_config.enabled_map())
        self.assertNotIn("claude:work", sources_config.order_ids())
        sources_config.reload_registry()
        self.assertNotIn("claude:work", sources_config.BY_ID)
        self.assertFalse(sources_config.remove_account("claude:work"))

    def test_rejects_input_worth_explaining(self):
        folder = self._claude_dir()
        sources_config.add_account("claude", "Work", folder)
        with self.assertRaisesRegex(ValueError, "already reads"):
            sources_config.add_account("claude", "Second", folder)
        with self.assertRaisesRegex(ValueError, "only one account"):
            sources_config.add_account("zed", "Work", folder)
        with self.assertRaisesRegex(ValueError, "not a folder"):
            sources_config.add_account(
                "claude", "Ghost", os.path.join(self.root, "nope"))
        with self.assertRaisesRegex(ValueError, "unknown provider"):
            sources_config.add_account("nonesuch", "Work", folder)

    def test_slugs_stay_unique_within_a_provider(self):
        first = sources_config.add_account(
            "claude", "Work", self._claude_dir("one"))
        second = sources_config.add_account(
            "claude", "Work", self._claude_dir("two"))
        self.assertEqual(first.slug, "work")
        self.assertEqual(second.slug, "work-2")

    def test_detection_probes_the_account_folder(self):
        sources_config.add_account(
            "claude", "Empty", self._claude_dir("blank", signed_in=False))
        sources_config.reload_registry()
        payload = sources_config.detection_payload()
        # A folder with no credentials in it is a visible row that says so,
        # not a row that quietly disappears.
        self.assertFalse(payload["detected"]["claude:empty"])
        self.assertIn(
            "claude:empty", [row["id"] for row in payload["sources"]])

    def test_reseeding_keeps_a_signed_in_account_on(self):
        sources_config.add_account("claude", "Work", self._claude_dir())
        sources_config.reload_registry()
        # Losing sources.json must not silently drop the second login: nothing
        # probes for a folder the registry was only just told about.
        os.remove(sources_config.STORE_PATH)
        sources_config.reset_for_tests()
        self.assertTrue(sources_config.enabled_map()["claude:work"])

    def test_setup_payload_lists_who_can_hold_accounts(self):
        providers = sources_config.accounts_payload()["providers"]
        by_id = {row["id"]: row for row in providers}
        self.assertEqual(by_id["claude"]["kind"], accounts.KIND_DIR)
        self.assertEqual(by_id["cursor"]["kind"], accounts.KIND_FILE)
        self.assertNotIn("zed", by_id)

    def test_store_survives_a_corrupt_file(self):
        with open(accounts.STORE_PATH, "w") as handle:
            handle.write("{ not json")
        accounts.reload()
        self.assertEqual(accounts.all_accounts(), {})

    def test_account_fetches_read_their_own_credentials(self):
        account = sources_config.add_account(
            "claude", "Work", self._claude_dir("creds", signed_in=False))
        sources_config.reload_registry()
        # No credentials in that folder: the row reports the path it looked
        # at, which is the only way to tell two Claude rows apart in an error.
        payload = sources_config.BY_ID["claude:work"].fetch(force=True)
        self.assertFalse(payload["ok"])
        self.assertIn(account.root, payload["error"])


if __name__ == "__main__":
    unittest.main()
