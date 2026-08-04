"""Balance meter arithmetic and OpenRouter / AI Gateway fetchers."""

from __future__ import annotations

import os
import tempfile
import unittest
from io import BytesIO
from unittest import mock
from urllib.error import HTTPError

import ai_gateway_usage
import headroom_server
import meters
import openrouter_usage
import sources_config


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

    def tearDown(self):
        openrouter_usage.invalidate()

    @mock.patch.dict("os.environ", {"OPENROUTER_API_KEY": "sk-or-mgmt"}, clear=False)
    @mock.patch("openrouter_usage._request")
    def test_fetch_maps_credits_to_balance(self, request):
        def _side_effect(path, token, timeout=15):
            if path == "/api/v1/key":
                return {"data": {"is_management_key": True}}
            if path == "/api/v1/credits":
                return {"data": {"total_credits": 100.0, "total_usage": 37.5}}
            raise AssertionError(f"unexpected path {path}")
        request.side_effect = _side_effect
        payload = openrouter_usage.fetch_quota(force=True)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["balance"]["remaining_usd"], 62.5)
        self.assertEqual(payload["balance"]["used_usd"], 37.5)
        self.assertEqual(payload["balance"]["topped_up_usd"], 100.0)

    @mock.patch.dict("os.environ", {"OPENROUTER_API_KEY": "sk-or-infer"}, clear=False)
    @mock.patch("openrouter_usage._request")
    def test_fetch_rejects_inference_key_even_when_credits_work(self, request):
        # OpenRouter may answer /credits for an inference key; Headroom still
        # refuses so Status shows the wrong key type instead of a quiet pot.
        def _side_effect(path, token, timeout=15):
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

    def tearDown(self):
        ai_gateway_usage.invalidate()

    @mock.patch.dict("os.environ", {"AI_GATEWAY_API_KEY": "gw-key"}, clear=False)
    @mock.patch("ai_gateway_usage.http_util.request_json")
    def test_fetch_maps_credits_to_balance(self, request):
        request.return_value = {"balance": "95.50", "total_used": "4.50"}
        payload = ai_gateway_usage.fetch_quota(force=True)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["balance"]["remaining_usd"], 95.5)
        self.assertEqual(payload["balance"]["used_usd"], 4.5)
        self.assertEqual(payload["balance"]["topped_up_usd"], 100.0)


if __name__ == "__main__":
    unittest.main()
