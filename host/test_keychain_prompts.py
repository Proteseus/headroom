#!/usr/bin/env python3
"""Keychain + Zed credential helpers that must not pop SecurityAgent."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import detect_sources
import keychain
import zed_usage


class DetectSourcesKeychainTests(unittest.TestCase):
    def test_github_probe_uses_fail_closed_read_token(self):
        with patch.object(keychain, "read_token", return_value="tok") as read:
            with patch.dict(os.environ, {}, clear=False):
                for key in ("HEADROOM_GITHUB_TOKEN", "GITHUB_TOKEN"):
                    os.environ.pop(key, None)
                self.assertTrue(detect_sources.github_signed_in())
        read.assert_called_once_with(
            "com.centaur-labs.headroom.github", "access-token",
            allow_ui=False)

    def test_datadog_needs_both_keys(self):
        seen = []

        def fake(service, account, allow_ui=True, **kwargs):
            seen.append((account, allow_ui))
            return "x" if account == "api-key" else None

        with patch.object(keychain, "read_token", side_effect=fake):
            with patch.dict(os.environ, {}, clear=False):
                for key in (
                    "DD_API_KEY", "HEADROOM_DATADOG_API_KEY",
                    "DD_APP_KEY", "DD_APPLICATION_KEY",
                    "HEADROOM_DATADOG_APP_KEY",
                ):
                    os.environ.pop(key, None)
                self.assertFalse(detect_sources.datadog_signed_in())
        self.assertEqual(
            seen,
            [("api-key", False), ("app-key", False)],
        )


class ZedKeychainTests(unittest.TestCase):
    def setUp(self):
        zed_usage.rearm_keychain()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(zed_usage.rearm_keychain)
        deny = Path(self.tmp.name) / ".denied-zed"
        self.patchers = [
            patch.object(zed_usage, "_deny_path", return_value=str(deny)),
            patch.object(zed_usage, "_settings_server",
                         return_value="zed.dev"),
        ]
        for p in self.patchers:
            p.start()
            self.addCleanup(p.stop)

    def test_signed_in_never_allows_ui(self):
        with patch.object(
            keychain, "get_internet_password",
            return_value=(keychain.ERR_SEC_SUCCESS, "tok", "user"),
        ) as internet:
            self.assertTrue(zed_usage.signed_in())
        internet.assert_called_once_with("zed.dev", allow_ui=False)

    def test_deny_sticks_across_fetches(self):
        with patch.object(
            keychain, "get_internet_password",
            return_value=(keychain.ERR_SEC_USER_CANCELED, None, None),
        ):
            with patch.object(
                keychain, "get_generic_password",
                return_value=(keychain.ERR_SEC_ITEM_NOT_FOUND, None),
            ):
                user, token = zed_usage._keychain_creds(allow_ui=True)
        self.assertIsNone(user)
        self.assertIsNone(token)
        self.assertTrue(os.path.isfile(zed_usage._deny_path()))

        with patch.object(keychain, "get_internet_password") as internet:
            self.assertIsNone(zed_usage._keychain_creds(allow_ui=True)[1])
        internet.assert_not_called()

        zed_usage.rearm_keychain()
        with patch.object(
            keychain, "get_internet_password",
            return_value=(keychain.ERR_SEC_SUCCESS, "tok", "u"),
        ) as internet:
            user, token = zed_usage._keychain_creds(allow_ui=True)
        self.assertEqual((user, token), ("u", "tok"))
        internet.assert_called_once_with("zed.dev", allow_ui=True)


if __name__ == "__main__":
    unittest.main()
