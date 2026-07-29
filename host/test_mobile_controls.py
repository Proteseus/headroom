"""Security boundary for authenticated iOS control routes."""

import unittest
from unittest import mock

import headroom_server


class MobileControlTests(unittest.TestCase):
    def handler(self, address="192.168.1.20", client="ios"):
        value = object.__new__(headroom_server.Handler)
        value.client_address = (address, 12345)
        value.headers = {"X-Headroom-Client": client}
        return value

    @mock.patch("headroom_server.auth.authorized_mobile", return_value=True)
    @mock.patch("headroom_server.app_config.mobile_permissions",
                return_value={"read", "refresh", "sources", "servers"})
    def test_paired_ios_gets_configured_private_network_scopes(
        self, _permissions, _authorized
    ):
        handler = self.handler()
        self.assertTrue(handler._mobile_permission_allowed("read"))
        self.assertTrue(handler._mobile_permission_allowed("refresh"))
        self.assertTrue(handler._mobile_permission_allowed("sources"))
        self.assertTrue(handler._mobile_permission_allowed("servers"))
        self.assertFalse(handler._mobile_permission_allowed("agents"))
        self.assertTrue(
            self.handler(address="100.101.102.103")
                ._mobile_permission_allowed("sources")
        )

    @mock.patch("headroom_server.auth.authorized_mobile", return_value=True)
    @mock.patch("headroom_server.app_config.mobile_permissions",
                return_value={"sources"})
    def test_unconfigured_scope_is_denied(self, _permissions, _authorized):
        self.assertFalse(self.handler()._mobile_permission_allowed("servers"))

    @mock.patch("headroom_server.auth.authorized_mobile", return_value=True)
    @mock.patch("headroom_server.app_config.mobile_permissions",
                return_value={"read", "refresh", "sources", "servers"})
    def test_public_address_and_unidentified_clients_are_denied(
        self, _permissions, _authorized
    ):
        self.assertFalse(
            self.handler(address="8.8.8.8")._mobile_permission_allowed("sources")
        )
        self.assertFalse(
            self.handler(client="browser")._mobile_permission_allowed("sources")
        )

    @mock.patch("headroom_server.auth.authorized_mobile", return_value=False)
    def test_unpaired_ios_is_denied(self, _authorized):
        self.assertFalse(
            self.handler()._mobile_permission_allowed("read")
        )

    @mock.patch("headroom_server.auth.authorized")
    @mock.patch("headroom_server.auth.authorized_mobile")
    def test_ios_header_selects_mobile_credential(
        self, authorized_mobile, authorized
    ):
        authorized_mobile.return_value = True
        self.assertTrue(self.handler()._allowed())
        authorized_mobile.assert_called_once()
        authorized.assert_not_called()

        authorized_mobile.reset_mock()
        authorized.return_value = True
        self.assertTrue(self.handler(client="esp32")._allowed())
        authorized.assert_called_once()
        authorized_mobile.assert_not_called()


if __name__ == "__main__":
    unittest.main()
