"""Balance meter arithmetic and OpenRouter / AI Gateway fetchers."""

from __future__ import annotations

import os
import tempfile
import unittest
from datetime import date
from io import BytesIO
from unittest import mock
from urllib.error import HTTPError

import ai_gateway_usage
import balance_spend
import cache_util
import headroom_server
import meters
import openrouter_usage
import sources_config


class BalanceSpendMathTests(unittest.TestCase):
    def test_build_spend_computes_runway(self):
        spend = balance_spend.build_spend(
            remaining_usd=70.0,
            by_day=[
                {"day": "2026-07-29", "usd": 10.0},
                {"day": "2026-07-30", "usd": 10.0},
                {"day": "2026-07-31", "usd": 10.0},
                {"day": "2026-08-01", "usd": 10.0},
                {"day": "2026-08-02", "usd": 10.0},
                {"day": "2026-08-03", "usd": 10.0},
                {"day": "2026-08-04", "usd": 10.0},
            ],
            by_model=[{"model": "x/y", "total_usage": 40.0, "request_count": 3}],
            today=date(2026, 8, 4),
            period_days=7,
        )
        self.assertEqual(spend["today_usd"], 10.0)
        self.assertEqual(spend["period_usd"], 70.0)
        self.assertEqual(spend["avg_daily_usd"], 10.0)
        self.assertEqual(spend["runway_days"], 7.0)
        self.assertEqual(spend["by_model"][0]["id"], "x/y")
        self.assertEqual(spend["by_model"][0]["requests"], 3)


class BalanceMeterTests(unittest.TestCase):
    def test_balance_reports_remaining_dollars(self):
        level, headroom = meters._balance({
            "remaining_usd": 42.5,
            "used_usd": 7.5,
            "topped_up_usd": 50.0,
        })
        self.assertEqual(level, 0.85)
        self.assertEqual(headroom, {"value": 42.5, "unit": "usd"})

    def test_balance_derives_level_from_lifetime_totals(self):
        level, headroom = meters._balance({
            "remaining_usd": 25.0,
            "used_usd": 75.0,
        })
        self.assertEqual(level, 0.25)
        self.assertEqual(headroom["value"], 25.0)

    def test_balance_without_denominator_has_no_level(self):
        level, headroom = meters._balance({"remaining_usd": 10.0})
        self.assertIsNone(level)
        self.assertEqual(headroom, {"value": 10.0, "unit": "usd"})

    def test_balance_missing_remaining_is_unmeasured(self):
        self.assertEqual(meters._balance({}), (None, None))


class BalanceProviderPayloadTests(unittest.TestCase):
    def setUp(self):
        sources_config.reset_for_tests()
        self.tmp = tempfile.TemporaryDirectory()
        self.patcher = mock.patch.object(
            sources_config, "STORE_PATH",
            os.path.join(self.tmp.name, "sources.json"))
        self.patcher.start()
        sources_config.set_enabled({
            "openrouter": True,
            "ai-gateway": True,
        })

    def tearDown(self):
        self.patcher.stop()
        self.tmp.cleanup()
        sources_config.reset_for_tests()

    def test_openrouter_balance_pool_shape(self):
        state = sources_config.blank_state()
        state["openrouter"] = {
            "ok": True,
            "configured": True,
            "balance": {
                "remaining_usd": 12.34,
                "used_usd": 7.66,
                "topped_up_usd": 20.0,
            },
            "spend": {
                "today_usd": 1.5,
                "period_days": 30,
                "period_usd": 20.0,
                "avg_daily_usd": 2.0,
                "runway_days": 6.2,
                "by_day": [{"day": "2026-08-04", "usd": 1.5}],
                "by_model": [{"id": "a/b", "title": "a/b", "usd": 1.5, "requests": 2}],
            },
        }
        row = next(
            r for r in headroom_server._providers_payload(state)
            if r["id"] == "openrouter"
        )
        pool = row["pools"]["balance"]
        self.assertEqual(pool["kind"], sources_config.KIND_BALANCE)
        self.assertEqual(pool["basis"], sources_config.BASIS_OBSERVED)
        self.assertEqual(pool["level"], 0.617)
        self.assertEqual(pool["headroom"], {"value": 12.34, "unit": "usd"})
        self.assertIsNone(pool["pct"])
        self.assertIsNone(pool["window_s"])
        self.assertIsNone(pool["resets_in_s"])
        self.assertFalse(pool["ring"])
        self.assertEqual(row["spend"]["runway_days"], 6.2)
        self.assertEqual(row["spend"]["today_usd"], 1.5)

    def test_balance_sources_are_quota_ai(self):
        by_id = {s.id: s for s in sources_config.SOURCES}
        for sid in ("openrouter", "ai-gateway"):
            self.assertEqual(by_id[sid].kind, "quota")
            self.assertEqual(by_id[sid].group, sources_config.GROUP_AI)
            self.assertEqual(
                by_id[sid].pools[0].kind, sources_config.KIND_BALANCE)
            self.assertEqual(by_id[sid].windows(), ())


class OpenRouterFetcherTests(unittest.TestCase):
    def setUp(self):
        openrouter_usage.invalidate()
        openrouter_usage._cache.update(t=0.0, data=None)
        # The fetcher writes a last-good disk snapshot on success; a private
        # cache dir keeps one test's snapshot out of another's failure path.
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        patcher = mock.patch.object(cache_util, "CACHE_DIR", tmp.name)
        patcher.start()
        self.addCleanup(patcher.stop)

    def tearDown(self):
        openrouter_usage.invalidate()

    @mock.patch.dict("os.environ", {"OPENROUTER_API_KEY": "sk-or-mgmt"}, clear=False)
    @mock.patch("openrouter_usage._request")
    def test_fetch_maps_credits_to_balance(self, request):
        def _side_effect(path, token, timeout=15, json_body=None, method=None):
            if path == "/api/v1/key":
                return {"data": {"is_management_key": True}}
            if path == "/api/v1/credits":
                return {"data": {"total_credits": 100.0, "total_usage": 37.5}}
            if path == "/api/v1/analytics/query":
                metrics = (json_body or {}).get("metrics") or []
                if "request_count" in metrics:
                    return {"data": {"data": [
                        {"model": "x/y", "total_usage": 5.0, "request_count": "2"},
                    ]}}
                return {"data": {"data": [
                    {"created_at__day": "2026-08-04", "total_usage": 1.25},
                ]}}
            if path == "/api/v1/keys":
                return {"data": [{
                    "name": "app",
                    "usage_daily": 1.25,
                    "usage_weekly": 4.0,
                    "usage_monthly": 12.0,
                }]}
            raise AssertionError(f"unexpected path {path}")
        request.side_effect = _side_effect
        payload = openrouter_usage.fetch_quota(force=True)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["balance"]["remaining_usd"], 62.5)
        self.assertEqual(payload["balance"]["used_usd"], 37.5)
        self.assertEqual(payload["balance"]["topped_up_usd"], 100.0)
        self.assertIsNotNone(payload["spend"])
        self.assertEqual(payload["spend"]["by_model"][0]["id"], "x/y")
        self.assertEqual(payload["spend"]["by_key"][0]["name"], "app")

    @mock.patch.dict("os.environ", {"OPENROUTER_API_KEY": "sk-or-infer"}, clear=False)
    @mock.patch("openrouter_usage._request")
    def test_fetch_rejects_inference_key_even_when_credits_work(self, request):
        def _side_effect(path, token, timeout=15, json_body=None, method=None):
            if path == "/api/v1/key":
                return {"data": {"is_management_key": False}}
            if path == "/api/v1/credits":
                return {"data": {"total_credits": 10.0, "total_usage": 1.0}}
            raise AssertionError(f"unexpected path {path}")
        request.side_effect = _side_effect
        payload = openrouter_usage.fetch_quota(force=True)
        self.assertFalse(payload["ok"])
        self.assertTrue(payload["configured"])
        self.assertIsNone(payload["balance"])
        self.assertIn("Inference key", payload["error"])
        self.assertIn("management-keys", payload["error"])
        request.assert_called_once()

    @mock.patch.dict("os.environ", {"OPENROUTER_API_KEY": "sk-or-bad"}, clear=False)
    @mock.patch("openrouter_usage._request")
    def test_fetch_rejects_non_management_key(self, request):
        request.side_effect = HTTPError(
            "https://openrouter.ai/api/v1/key", 403, "Forbidden",
            hdrs=None, fp=BytesIO(b"{}"))
        payload = openrouter_usage.fetch_quota(force=True)
        self.assertFalse(payload["ok"])
        self.assertTrue(payload["configured"])
        self.assertIn("Management", payload["error"])
        self.assertIn("management-keys", payload["error"])


class AIGatewayFetcherTests(unittest.TestCase):
    def setUp(self):
        ai_gateway_usage.invalidate()
        ai_gateway_usage._cache.update(t=0.0, data=None)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        patcher = mock.patch.object(cache_util, "CACHE_DIR", tmp.name)
        patcher.start()
        self.addCleanup(patcher.stop)

    def tearDown(self):
        ai_gateway_usage.invalidate()

    @mock.patch.dict("os.environ", {"AI_GATEWAY_API_KEY": "gw-key"}, clear=False)
    @mock.patch("ai_gateway_usage.http_util.request_json")
    def test_fetch_maps_credits_to_balance(self, request):
        def _side_effect(url, **kwargs):
            if url.endswith("/v1/credits"):
                return {"balance": "95.50", "total_used": "4.50"}
            if "/v1/report" in url or kwargs.get("query", {}).get("group_by") == "day":
                group = (kwargs.get("query") or {}).get("group_by")
                if group == "model":
                    return {"results": [
                        {"model": "anthropic/x", "total_cost": 2.5, "request_count": 4},
                    ]}
                return {"results": [
                    {"day": "2026-08-04", "total_cost": 1.0},
                ]}
            raise AssertionError(url)
        request.side_effect = _side_effect
        payload = ai_gateway_usage.fetch_quota(force=True)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["balance"]["remaining_usd"], 95.5)
        self.assertEqual(payload["balance"]["used_usd"], 4.5)
        self.assertEqual(payload["balance"]["topped_up_usd"], 100.0)
        self.assertIsNotNone(payload["spend"])
        self.assertEqual(payload["spend"]["by_model"][0]["id"], "anthropic/x")

    @mock.patch.dict("os.environ", {"AI_GATEWAY_API_KEY": "gw-key"}, clear=False)
    @mock.patch("ai_gateway_usage.http_util.request_json")
    def test_fetch_keeps_balance_when_report_forbidden(self, request):
        def _side_effect(url, **kwargs):
            if url.endswith("/v1/credits"):
                return {"balance": "10", "total_used": "1"}
            raise HTTPError(
                "https://ai-gateway.vercel.sh/v1/report", 403, "Forbidden",
                hdrs=None, fp=BytesIO(b"{}"))
        request.side_effect = _side_effect
        payload = ai_gateway_usage.fetch_quota(force=True)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["balance"]["remaining_usd"], 10.0)
        self.assertIn("Pro or Enterprise", payload["spend"]["report_error"])


if __name__ == "__main__":
    unittest.main()
