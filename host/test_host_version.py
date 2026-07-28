"""The version handshake, checked against the Swift half.

The fingerprint rule crosses a language boundary — Python computes it for the
running host, Swift computes it for the copy bundled in Headroom.app, and the
app compares the two. If the rules drift, the app either nags about skew that
isn't there or (worse) reports "up to date" while running last week's scrapers.

GOLDEN_BUILD below is the same constant as in macos/Tests/HostVersionTests.swift
over the same synthetic tree. Change one without the other and a test fails.
"""

from __future__ import annotations

import os
import tempfile
import unittest

import headroom_server
import host_version

# sha256 over VERSION + alpha.py + zeta.py as laid out in _golden_tree().
GOLDEN_BUILD = "bc208b82c08c"


def _golden_tree(directory):
    """A host directory in miniature: a version, two modules, and two decoys."""
    files = {
        "VERSION": "9.9.9\n",
        "alpha.py": "print('a')\n",
        "zeta.py": "print('z')\n",
        # Neither of these ships inside the .app, so neither may move the hash.
        "test_alpha.py": "ignored\n",
        "notes.md": "ignored\n",
    }
    for name, body in files.items():
        with open(os.path.join(directory, name), "w") as handle:
            handle.write(body)
    cache = os.path.join(directory, "__pycache__")
    os.mkdir(cache)
    with open(os.path.join(cache, "alpha.pyc"), "w") as handle:
        handle.write("ignored\n")


class HostVersionTest(unittest.TestCase):
    def test_golden_build_matches_the_swift_constant(self):
        with tempfile.TemporaryDirectory() as directory:
            _golden_tree(directory)
            self.assertEqual(host_version.build(directory), GOLDEN_BUILD)

    def test_shipped_files_exclude_tests_and_caches(self):
        with tempfile.TemporaryDirectory() as directory:
            _golden_tree(directory)
            self.assertEqual(
                host_version.shipped_files(directory),
                ["VERSION", "alpha.py", "zeta.py"],
            )

    def test_editing_a_module_moves_the_build(self):
        with tempfile.TemporaryDirectory() as directory:
            _golden_tree(directory)
            before = host_version.build(directory)
            with open(os.path.join(directory, "alpha.py"), "w") as handle:
                handle.write("print('a2')\n")
            self.assertNotEqual(host_version.build(directory), before)

    def test_editing_a_test_file_does_not_move_the_build(self):
        with tempfile.TemporaryDirectory() as directory:
            _golden_tree(directory)
            before = host_version.build(directory)
            with open(os.path.join(directory, "test_alpha.py"), "w") as handle:
                handle.write("still ignored, differently\n")
            self.assertEqual(host_version.build(directory), before)

    def test_bumping_version_moves_the_build(self):
        """VERSION is hashed too, so a release bump alone counts as a new build."""
        with tempfile.TemporaryDirectory() as directory:
            _golden_tree(directory)
            before = host_version.build(directory)
            with open(os.path.join(directory, "VERSION"), "w") as handle:
                handle.write("9.9.10\n")
            self.assertNotEqual(host_version.build(directory), before)

    def test_version_falls_back_when_the_file_is_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(
                host_version.version(directory), host_version.FALLBACK_VERSION)

    def test_this_checkout_reports_a_real_version(self):
        self.assertRegex(host_version.version(), r"^\d+\.\d+\.\d+$")
        self.assertRegex(host_version.build(), r"^[0-9a-f]{12}$")


class HealthPayloadTest(unittest.TestCase):
    """/health is where the app reads the handshake; keep the keys pinned."""

    def test_health_carries_version_and_build(self):
        payload = headroom_server._health_payload()
        self.assertEqual(payload["version"], host_version.version())
        self.assertEqual(payload["build"], host_version.build())

    def test_health_still_carries_the_older_keys(self):
        payload = headroom_server._health_payload()
        for key in ("ok", "uptime_s", "updated", "sources"):
            self.assertIn(key, payload)


if __name__ == "__main__":
    unittest.main()
