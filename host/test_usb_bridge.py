"""Tests for the USB CDC HR framing helpers (no real serial device)."""

from __future__ import annotations

import os
import unittest
from unittest import mock

import usb_bridge


class FrameTests(unittest.TestCase):
    def test_is_hr_line(self):
        self.assertTrue(usb_bridge.is_hr_line("HR GET /usage"))
        self.assertFalse(usb_bridge.is_hr_line("boot ok"))
        self.assertFalse(usb_bridge.is_hr_line("hr GET /usage"))

    def test_parse_request_line(self):
        self.assertEqual(
            usb_bridge.parse_request_line("HR GET /usage"),
            ("GET", "/usage"),
        )
        self.assertEqual(
            usb_bridge.parse_request_line("HR POST /sync/refresh\n"),
            ("POST", "/sync/refresh"),
        )
        self.assertIsNone(usb_bridge.parse_request_line("wifi ok ip=1.2.3.4"))
        self.assertIsNone(usb_bridge.parse_request_line("HR GET"))
        self.assertIsNone(usb_bridge.parse_request_line("HR FOO /usage"))
        self.assertIsNone(usb_bridge.parse_request_line("HR GET usage"))

    def test_format_reply_empty(self):
        self.assertEqual(usb_bridge.format_reply(202), b"HR 202 0\n\n")
        self.assertEqual(usb_bridge.format_reply(404, b""), b"HR 404 0\n\n")

    def test_format_reply_body(self):
        body = b'{"ok":true}'
        framed = usb_bridge.format_reply(200, body)
        self.assertEqual(framed, b"HR 200 11\n" + body + b"\n")

    def test_handle_get_usage(self):
        reply = usb_bridge.handle_request(
            "GET", "/usage",
            get_usage=lambda: b'{"plan":"Max"}',
            on_sync_refresh=lambda: None,
        )
        self.assertEqual(reply, b'HR 200 14\n{"plan":"Max"}\n')

    def test_handle_sync_refresh(self):
        called = []
        reply = usb_bridge.handle_request(
            "POST", "/sync/refresh",
            get_usage=lambda: b"",
            on_sync_refresh=lambda: called.append(1),
        )
        self.assertEqual(called, [1])
        self.assertEqual(reply, b"HR 202 0\n\n")

    def test_a_query_string_still_routes(self):
        # The board hangs its build id off the path. Matching the whole path
        # would 404 every versioned board.
        reply = usb_bridge.handle_request(
            "GET", "/usage?fw=12.3db3cff",
            get_usage=lambda: b'{"plan":"Max"}',
            on_sync_refresh=lambda: None,
        )
        self.assertEqual(reply, b'HR 200 14\n{"plan":"Max"}\n')

    def test_the_query_reaches_the_device_hook(self):
        seen = []
        usb_bridge.handle_request(
            "GET", "/usage?fw=12.3db3cff-dirty",
            get_usage=lambda: b"x",
            on_sync_refresh=lambda: None,
            on_device=seen.append,
        )
        self.assertEqual(seen, ["fw=12.3db3cff-dirty"])

    def test_a_broken_device_hook_still_serves_the_document(self):
        def boom(_):
            raise ValueError("bad report")

        reply = usb_bridge.handle_request(
            "GET", "/usage?fw=junk",
            get_usage=lambda: b"x",
            on_sync_refresh=lambda: None,
            on_device=boom,
        )
        self.assertEqual(reply, b"HR 200 1\nx\n")

    def test_handle_unknown(self):
        reply = usb_bridge.handle_request(
            "GET", "/nope",
            get_usage=lambda: b"x",
            on_sync_refresh=lambda: None,
        )
        self.assertEqual(reply, b"HR 404 0\n\n")

    def test_ignore_non_hr_in_parse(self):
        # Simulate a debug log line mixed into the stream — must not dispatch.
        self.assertIsNone(usb_bridge.parse_request_line(
            "host=usb  fetch ok  claude=1"))


class CandidatePortTests(unittest.TestCase):
    def test_override_wins(self):
        self.assertEqual(
            usb_bridge.candidate_ports(override="/dev/cu.usbmodemTEST"),
            ["/dev/cu.usbmodemTEST"],
        )

    def test_env_override(self):
        with mock.patch.dict(os.environ, {"HEADROOM_USB_PORT": "/dev/cu.env"}):
            self.assertEqual(
                usb_bridge.candidate_ports(),
                ["/dev/cu.env"],
            )


class WriteAllTests(unittest.TestCase):
    def test_write_all_retries_partial(self):
        chunks = []

        class FakeFd:
            def __init__(self):
                self.calls = 0

        fd = FakeFd()

        def fake_write(_fd, data):
            fd.calls += 1
            if fd.calls == 1:
                chunks.append(bytes(data[:4]))
                return 4
            chunks.append(bytes(data))
            return len(data)

        with mock.patch.object(usb_bridge.os, "write", side_effect=fake_write), \
             mock.patch.object(usb_bridge.select, "select",
                               return_value=([], [fd], [])):
            ok = usb_bridge._write_all(fd, b"abcdefgh")
        self.assertTrue(ok)
        self.assertEqual(b"".join(chunks), b"abcdefgh")
        self.assertGreaterEqual(fd.calls, 2)


if __name__ == "__main__":
    unittest.main()
