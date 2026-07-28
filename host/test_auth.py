"""Tests for the general and mobile credential boundary."""

import os
import tempfile
import unittest
from unittest import mock

import auth


class AuthTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.general_path = os.path.join(self.tempdir.name, "token")
        self.mobile_path = os.path.join(self.tempdir.name, "mobile-token")
        self.patches = [
            mock.patch.object(auth, "TOKEN_PATH", self.general_path),
            mock.patch.object(auth, "MOBILE_TOKEN_PATH", self.mobile_path),
            mock.patch("auth.app_config.get", side_effect=self.config_value),
        ]
        for patch in self.patches:
            patch.start()
        auth.reset_for_tests()

    def tearDown(self):
        auth.reset_for_tests()
        for patch in reversed(self.patches):
            patch.stop()
        self.tempdir.cleanup()

    @staticmethod
    def config_value(key, default=None):
        if key == "require_auth":
            return True
        return default

    def test_general_and_mobile_credentials_are_distinct(self):
        general = auth.token()
        mobile = auth.mobile_token()

        self.assertNotEqual(general, mobile)
        self.assertTrue(auth.authorized({auth.HEADER: general}))
        self.assertFalse(auth.authorized({auth.HEADER: mobile}))
        self.assertTrue(auth.authorized_mobile({auth.HEADER: mobile}))
        self.assertFalse(auth.authorized_mobile({auth.HEADER: general}))

    def test_generated_credentials_are_private_files(self):
        auth.token()
        auth.mobile_token()

        self.assertEqual(os.stat(self.general_path).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(self.mobile_path).st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
