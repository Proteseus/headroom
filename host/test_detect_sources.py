#!/usr/bin/env python3
"""First-run source detection + seeding."""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import detect_sources
import sources_config


class DetectSourcesTests(unittest.TestCase):
    def test_suggested_enables_detected_only(self):
        with patch.object(detect_sources, "detected_map", return_value={
            "claude": True,
            "codex": False,
            "cursor": False,
            "vercel": False,
            "git": False,
            "github": False,
            "local": True,
            "supabase": False,
            "plausible": False,
        }):
            got = detect_sources.suggested_enabled(
                ("claude", "codex", "cursor", "vercel", "git",
                 "github", "local", "supabase", "plausible"))
        self.assertTrue(got["claude"])
        self.assertFalse(got["codex"])
        self.assertFalse(got["cursor"])
        self.assertTrue(got["local"])
        self.assertFalse(got["vercel"])
        self.assertFalse(got["plausible"])

    def test_suggested_falls_back_when_no_quota_detected(self):
        with patch.object(detect_sources, "detected_map", return_value={
            "claude": False, "codex": False, "cursor": False,
            "vercel": False, "git": False, "github": False,
            "local": True, "supabase": False, "plausible": False,
        }):
            got = detect_sources.suggested_enabled(
                ("claude", "codex", "cursor", "local"))
        self.assertTrue(got["claude"])
        self.assertTrue(got["codex"])
        self.assertTrue(got["cursor"])
        self.assertTrue(got["local"])


class SeedSourcesTests(unittest.TestCase):
    def setUp(self):
        sources_config.reset_for_tests()
        self.tmp = tempfile.TemporaryDirectory()
        self.path = str(Path(self.tmp.name) / "sources.json")
        self.patcher = patch.object(sources_config, "STORE_PATH", self.path)
        self.patcher.start()

    def tearDown(self):
        self.patcher.stop()
        self.tmp.cleanup()
        sources_config.reset_for_tests()

    def test_missing_file_is_seeded_from_detection(self):
        with patch.object(detect_sources, "detected_map", return_value={
            "claude": True,
            "codex": False,
            "cursor": True,
            "vercel": False,
            "git": True,
            "github": False,
            "local": True,
            "supabase": False,
            "plausible": False,
        }):
            enabled = sources_config.enabled_map()
        self.assertTrue(enabled["claude"])
        self.assertFalse(enabled["codex"])
        self.assertTrue(enabled["cursor"])
        self.assertTrue(os.path.isfile(self.path))
        with open(self.path) as handle:
            saved = json.load(handle)
        self.assertEqual(saved.get("seeded_from"), "detect")
        self.assertFalse(saved["enabled"]["codex"])
        self.assertFalse(saved["enabled"].get("plausible", False))


if __name__ == "__main__":
    unittest.main()
