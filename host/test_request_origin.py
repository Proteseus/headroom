"""The two checks that keep a web page from driving this host.

The host binds a fixed port, waves loopback callers through without a
credential, and is advertised over mDNS. That combination is exactly what
DNS rebinding targets: a page on `evil.tld` whose DNS answer flips to
127.0.0.1 arrives on a loopback socket and, without these checks, inherits
the whole Mac-local class — starting an agent task, reading `/config/git`,
restarting the host.

What such a page cannot forge is the `Host` header (it is the name it had to
resolve) or the absence of `Origin` / `Sec-Fetch-Site` (browsers always send
them, and no real Headroom client does).
"""

from __future__ import annotations

import unittest

import headroom_server


class _FakeHandler(headroom_server.Handler):
    """Handler with the socket and headers stubbed, no server, no I/O."""

    def __init__(self, headers=None, peer="127.0.0.1"):
        self.headers = dict(headers or {})
        self.client_address = (peer, 51234)


class HostHeaderTests(unittest.TestCase):
    def test_a_loopback_socket_naming_localhost_is_local(self):
        for value in ("127.0.0.1:8737", "localhost:8737", "[::1]:8737",
                      "127.0.0.1", "localhost"):
            handler = _FakeHandler({"Host": value})
            self.assertTrue(
                handler._is_loopback(), f"{value} should count as local")

    def test_a_missing_host_header_still_counts(self):
        # The board and curl may omit it; the socket check still applies.
        self.assertTrue(_FakeHandler({})._is_loopback())

    def test_a_rebound_name_on_a_loopback_socket_is_not_local(self):
        # The rebinding case: the packet is genuinely from 127.0.0.1, but
        # the browser still names the site it resolved.
        for value in ("evil.tld", "evil.tld:8737", "headroom.evil.tld:8737"):
            handler = _FakeHandler({"Host": value})
            self.assertFalse(
                handler._is_loopback(), f"{value} must not count as local")

    def test_a_lan_peer_is_never_local_whatever_it_claims(self):
        handler = _FakeHandler({"Host": "127.0.0.1:8737"}, peer="192.168.1.9")
        self.assertFalse(handler._is_loopback())


class CrossOriginTests(unittest.TestCase):
    def test_no_origin_headers_is_a_real_client(self):
        self.assertFalse(_FakeHandler({})._is_browser_cross_origin())

    def test_a_page_on_another_site_is_refused(self):
        for origin in ("http://evil.tld", "https://evil.tld:8443",
                       "http://sub.evil.tld"):
            handler = _FakeHandler({"Origin": origin})
            self.assertTrue(
                handler._is_browser_cross_origin(), f"{origin} must be refused")

    def test_sec_fetch_site_alone_is_enough_to_refuse(self):
        for value in ("cross-site", "same-site"):
            handler = _FakeHandler({"Sec-Fetch-Site": value})
            self.assertTrue(handler._is_browser_cross_origin())

    def test_a_loopback_origin_is_allowed(self):
        # Nothing ships one today, but a local tool serving its own page
        # should not be collateral damage.
        for origin in ("http://127.0.0.1:8737", "http://localhost:3000",
                       "null"):
            handler = _FakeHandler({"Origin": origin})
            self.assertFalse(
                handler._is_browser_cross_origin(), f"{origin} should pass")

    def test_same_origin_navigation_is_allowed(self):
        handler = _FakeHandler(
            {"Sec-Fetch-Site": "same-origin", "Host": "127.0.0.1:8737"})
        self.assertFalse(handler._is_browser_cross_origin())


if __name__ == "__main__":
    unittest.main()
