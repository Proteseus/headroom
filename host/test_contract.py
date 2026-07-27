"""The /usage contract, checked against both clients.

The document shape is written down three times — Python dicts here, Swift
Codable structs in macos/Sources/Models.swift, and field reads in
firmware/src/main.cpp — and nothing forced them to agree. Renaming a key was a
silent break: Swift decodes it to nil, the board renders "--", and neither
fails loudly.

These tests pin the parts that cross a process boundary. The Swift half lives
in macos/Tests/ContractTests.swift.
"""

from __future__ import annotations

import json
import os
import re
import unittest

import device_view
import headroom_server
import sources_config

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEMO_PATH = os.path.join(REPO_ROOT, "docs", "demo_usage.json")
FIRMWARE_PATH = os.path.join(REPO_ROOT, "firmware", "src", "main.cpp")


def _demo_doc():
    with open(DEMO_PATH) as handle:
        return json.load(handle)


def _firmware_filter_paths():
    """Key paths from usageFilter() in main.cpp, e.g. ('vercel', 'deployments')."""
    with open(FIRMWARE_PATH) as handle:
        source = handle.read()
    start = source.index("static JsonDocument usageFilter()")
    end = source.index("\n}", start)
    body = source[start:end]

    paths = set()
    # filter["a"]["b"][0]["c"] = true;  → ("a", "b", "c")
    for line in body.splitlines():
        line = line.strip()
        if not line.startswith("filter["):
            continue
        keys = re.findall(r'\["([^"]+)"\]', line)
        if keys:
            paths.add(tuple(keys))
    # The flat top-level block is written as a loop over a string list.
    for match in re.finditer(r'for \(const char \*key : \{(.+?)\}\)', body, re.S):
        for key in re.findall(r'"([^"]+)"', match.group(1)):
            paths.add((key,))
    return paths


# What device_view is capable of emitting, derived from its own constants so
# the test can't drift from the projection it is checking.
EMITTABLE = (
    {(key,) for key in device_view.CLAUDE_FIELDS}
    | {("updated",)}
    | {("codex", key) for key in device_view.CODEX_FIELDS}
    | {("cursor", key) for key in device_view.CURSOR_FIELDS}
    | {("codex",), ("cursor",)}
    | {("vercel",), ("vercel", "ok"), ("vercel", "team"),
       ("vercel", "deployments")}
    | {("vercel", "deployments", key) for key in device_view.DEPLOY_FIELDS}
    | {("git",), ("git", "ok"), ("git", "commits")}
    | {("git", "commits", key) for key in device_view.COMMIT_FIELDS}
    | {("local",), ("local", "ok"), ("local", "host"), ("local", "servers")}
    | {("local", "servers", key) for key in device_view.SERVER_FIELDS}
    | {("sources",)}
    | {("sources", key) for key in device_view.SOURCE_FIELDS}
    | {("burndown",)}
    | {("burndown", provider) for provider in ("claude", "codex", "cursor")}
    | {("burndown", provider, key)
       for provider in ("claude", "codex", "cursor")
       for key in device_view.BURNDOWN_FIELDS}
)


class DeviceViewContractTests(unittest.TestCase):
    def test_firmware_filter_only_asks_for_emittable_keys(self):
        """Every key the board filters for is one the host can actually send."""
        missing = sorted(_firmware_filter_paths() - EMITTABLE)
        self.assertEqual(
            missing, [],
            "firmware/src/main.cpp usageFilter() wants keys device_view.py "
            "never emits — one side was renamed without the other",
        )

    def test_device_view_survives_a_fully_populated_document(self):
        device = device_view.build(_demo_doc())
        self.assertTrue(device["quota_ok"])
        self.assertEqual(device["plan"], "Max 5x")
        self.assertTrue(device["codex"]["ok"])
        self.assertIn("total_pct", device["cursor"])
        self.assertTrue(device["vercel"]["deployments"])
        self.assertTrue(device["git"]["commits"])
        self.assertTrue(device["sources"])

    def test_device_view_drops_nulls(self):
        doc = {"plan": None, "week_pct": 12.0, "updated": "x",
               "codex": {"ok": True, "plan": None}}
        device = device_view.build(doc)
        self.assertNotIn("plan", device)
        self.assertEqual(device["week_pct"], 12.0)
        self.assertNotIn("plan", device["codex"])

    def test_device_view_caps_rows_to_firmware_storage(self):
        doc = {
            "vercel": {"ok": True, "deployments": [{"project": f"p{i}"}
                                                   for i in range(20)]},
            "git": {"ok": True, "commits": [{"repo": f"r{i}"}
                                            for i in range(20)]},
            "local": {"ok": True, "servers": [{"name": f"s{i}"}
                                              for i in range(20)]},
        }
        device = device_view.build(doc)
        self.assertEqual(len(device["vercel"]["deployments"]),
                         device_view.MAX_DEPLOYS)
        self.assertEqual(len(device["git"]["commits"]), device_view.MAX_COMMITS)
        self.assertEqual(len(device["local"]["servers"]),
                         device_view.MAX_SERVERS)

    def test_device_row_caps_match_firmware_constants(self):
        with open(FIRMWARE_PATH) as handle:
            source = handle.read()

        def firmware_const(name):
            match = re.search(
                rf"static const uint8_t {name} = (\d+);", source)
            self.assertIsNotNone(match, f"{name} missing from main.cpp")
            return int(match.group(1))

        self.assertEqual(firmware_const("MAX_DEPLOYS"), device_view.MAX_DEPLOYS)
        self.assertEqual(firmware_const("MAX_COMMITS"), device_view.MAX_COMMITS)
        self.assertEqual(firmware_const("MAX_SERVERS"), device_view.MAX_SERVERS)
        self.assertEqual(firmware_const("MAX_SOURCES"), device_view.MAX_SOURCES)

    def test_device_payload_is_much_smaller_than_the_full_document(self):
        doc = _demo_doc()
        full = len(json.dumps(doc))
        device = len(json.dumps(device_view.build(doc), separators=(",", ":")))
        self.assertLess(device, full // 2)

    def test_cursor_burndown_overlays_total_and_api(self):
        """Cursor ships Total + API on one chart; Auto is never the second line."""
        window = {
            "window_s": 30 * 24 * 3600,
            "window_start": 1_700_000_000,
            "window_end": 1_700_000_000 + 30 * 24 * 3600,
            "actual": [[1_700_000_100, 90.0], [1_700_000_200, 80.0]],
            "projected": [[1_700_000_200, 80.0], [1_700_100_000, 0.0]],
            "exhausts_before_reset": False,
            "rate_source": "measured",
        }
        doc = {
            "burndown": {
                "cursor": {
                    "total": {**window, "pool": "total", "status": "ok"},
                    "auto": {**window, "pool": "auto", "status": "ok",
                             "actual": [[1_700_000_100, 100.0]]},
                    "api": {**window, "pool": "api", "status": "exhausted",
                            "actual": [[1_700_000_100, 40.0],
                                       [1_700_000_200, 0.0]],
                            "exhausts_before_reset": True},
                }
            }
        }
        device = device_view.build(doc)
        burn = device["burndown"]["cursor"]
        self.assertEqual(burn["pool"], "total")
        self.assertEqual(burn["pool2"], "api")
        self.assertEqual(burn["status2"], "exhausted")
        self.assertTrue(burn["warn2"])
        self.assertEqual(burn["pts2"][-1][1], 0.0)
        self.assertNotIn("auto", json.dumps(burn))


class RollupContractTests(unittest.TestCase):
    def test_rollup_exposes_every_registered_source(self):
        doc = headroom_server.publish()
        ids = [row["id"] for row in doc["sources"]]
        self.assertEqual(ids, list(sources_config.SOURCE_IDS))

    def test_rollup_has_the_keys_the_mac_app_decodes(self):
        doc = headroom_server.publish()
        for key in ("updated", "today", "by_day", "codex", "cursor", "vercel",
                    "git", "github", "activity", "local", "supabase",
                    "sources", "attention", "quota_ok", "session_pct",
                    "week_pct"):
            self.assertIn(key, doc)

    def test_demo_fixture_matches_the_served_shape(self):
        """The README fixture must stay decodable as a real response."""
        served = set(headroom_server.publish().keys())
        demo = set(_demo_doc().keys())
        unknown = sorted(demo - served)
        self.assertEqual(
            unknown, [],
            "docs/demo_usage.json has keys the host no longer serves",
        )


class AttentionContractTests(unittest.TestCase):
    def test_attention_never_leaks_internal_weights(self):
        doc = headroom_server.publish()
        for reason in doc["attention"]["reasons"]:
            self.assertNotIn("weight", reason)

    def test_attention_levels_are_known_values(self):
        doc = headroom_server.publish()
        self.assertIn(doc["attention"]["level"], ("ok", "warn", "critical"))


if __name__ == "__main__":
    unittest.main()
