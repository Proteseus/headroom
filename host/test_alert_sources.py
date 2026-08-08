"""Unit tests for Sentry / Datadog / Axiom Attention fetch helpers."""

from __future__ import annotations

import time
import unittest
from unittest import mock

import axiom_monitors
import datadog_monitors
import headroom_server
import sentry_alerts


class SentryAlertsTests(unittest.TestCase):
    def test_flattens_issue(self):
        row = sentry_alerts._flatten_issue({
            "id": "123",
            "shortId": "APP-1",
            "title": "TypeError: x",
            "level": "error",
            "lastSeen": "2026-08-03T12:00:00Z",
            "project": {"slug": "app"},
            "permalink": "https://sentry.io/issues/123/",
        }, "acme")
        self.assertEqual(row["id"], "123")
        self.assertEqual(row["project"], "app")
        self.assertEqual(row["status"], "error")
        self.assertEqual(row["url"], "https://sentry.io/issues/123/")

    def test_fresh_gate(self):
        now = time.time()
        fresh = {"last_seen": now - 60}
        stale = {"last_seen": now - 48 * 3600}
        self.assertTrue(sentry_alerts._is_fresh(fresh, now))
        self.assertFalse(sentry_alerts._is_fresh(stale, now))


class DatadogMonitorsTests(unittest.TestCase):
    def test_flattens_alert_monitor(self):
        row = datadog_monitors._flatten_monitor({
            "id": 9,
            "name": "High error rate",
            "overall_state": "Alert",
            "overall_state_modified": 1_700_000_000,
        }, "datadoghq.com")
        self.assertEqual(row["id"], "9")
        self.assertEqual(row["status"], "error")
        self.assertEqual(row["overall_state"], "Alert")
        self.assertIn("monitors/9", row["url"])


class AxiomMonitorsTests(unittest.TestCase):
    def test_open_from_status_field(self):
        self.assertTrue(axiom_monitors._monitor_open_from_fields(
            {"status": "open"}))
        self.assertFalse(axiom_monitors._monitor_open_from_fields(
            {"state": "closed"}))
        self.assertIsNone(axiom_monitors._monitor_open_from_fields({}))

    def test_flattens_alert(self):
        row = axiom_monitors._flatten_alert(
            {"id": "mon_1", "name": "Errors", "type": "Threshold"},
            1_700_000_000,
            "https://api.axiom.co",
        )
        self.assertEqual(row["id"], "mon_1")
        self.assertEqual(row["status"], "error")
        self.assertIn("app.axiom.co", row["url"])


class AlertActivityMergeTests(unittest.TestCase):
    def test_merges_sentry_datadog_axiom_into_activity(self):
        now = time.time()
        items = headroom_server._build_activity(
            {}, {},
            sentry={
                "issues": [{
                    "id": "1",
                    "title": "Boom",
                    "project": "web",
                    "last_seen": now,
                    "ago": "1m",
                    "url": "https://sentry.io/1",
                    "level": "error",
                }],
            },
            datadog={
                "monitors": [{
                    "id": "2",
                    "name": "CPU",
                    "overall_state": "Alert",
                    "created_at": now,
                    "ago": "2m",
                    "url": "https://app.datadoghq.com/monitors/2",
                }],
            },
            axiom={
                "alerts": [{
                    "id": "3",
                    "name": "Latency",
                    "type": "Threshold",
                    "created_at": now,
                    "ago": "3m",
                    "url": "https://app.axiom.co/monitors/3",
                }],
            },
        )
        kinds = {item["kind"] for item in items}
        self.assertIn("sentry", kinds)
        self.assertIn("datadog", kinds)
        self.assertIn("axiom", kinds)
        for item in items:
            if item["kind"] in ("sentry", "datadog", "axiom"):
                self.assertEqual(item["status"], "error")

    def test_attention_scores_alert_sources(self):
        doc = {
            "github": {},
            "claude_status": {},
            "supabase": {},
            "vercel": {"deployments": []},
            "providers": [],
            "sentry": {"configured": True, "alert_count": 3},
            "datadog": {"configured": True, "alert_count": 2, "warn_count": 0},
            "axiom": {"configured": True, "alert_count": 2},
        }
        with mock.patch("headroom_server.app_config.attention_ack_fingerprint",
                        return_value=""):
            attention = headroom_server._build_attention(doc)
        kinds = {r["kind"] for r in attention["reasons"]}
        self.assertIn("sentry", kinds)
        self.assertIn("datadog", kinds)
        self.assertIn("axiom", kinds)
        self.assertEqual(attention["level"], "critical")


if __name__ == "__main__":
    unittest.main()
