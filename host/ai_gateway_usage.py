"""Vercel AI Gateway prepaid credit balance + spend leaf for Headroom.

Separate from the existing `vercel` deployments source: that one reads the
Vercel CLI login and lists deploys. This one watches AI Gateway credits via
`GET https://ai-gateway.vercel.sh/v1/credits`, and (on Pro/Enterprise) the
spend report via `GET /v1/report`.

Uses a Gateway API key from, in order: AI_GATEWAY_API_KEY /
HEADROOM_AI_GATEWAY_TOKEN / VERCEL_OIDC_TOKEN, or the Headroom macOS Keychain
item. Tokens are never returned in payloads or logs. Stdlib only.
"""

from __future__ import annotations

import os
import time
import urllib.error

import balance_spend
import cache_util
import http_util
import keychain

API_HOST = "https://ai-gateway.vercel.sh"
CACHE_TTL_S = 2 * 60
FAIL_TTL_S = 45
KEYCHAIN_SERVICE = "com.centaur-labs.headroom.ai-gateway"
KEYCHAIN_ACCOUNT = "access-token"
DISK = "ai_gateway_quota"

_cache = {"t": 0.0, "data": None}
_EMPTY = {
    "ok": False,
    "configured": False,
    "error": None,
    "plan": None,
    "balance": None,
    "spend": None,
}


def _keychain_token():
    return keychain.read_token(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)


def _token():
    for key in (
        "AI_GATEWAY_API_KEY",
        "HEADROOM_AI_GATEWAY_TOKEN",
        "VERCEL_OIDC_TOKEN",
    ):
        token = os.environ.get(key)
        if token:
            return token.strip()
    return _keychain_token()


def has_token():
    """True when any credential source has a value — not that it works."""
    return bool(_token())


def invalidate():
    _cache.update(t=0.0)


def _as_float(value):
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(str(value).strip())
    except (TypeError, ValueError):
        return None


def _balance_bucket(balance, total_used):
    remaining = max(0.0, balance)
    used = max(0.0, total_used) if total_used is not None else None
    topped = None
    if used is not None:
        topped = remaining + used
    return {
        "remaining_usd": round(remaining, 4),
        "used_usd": None if used is None else round(used, 4),
        "topped_up_usd": None if topped is None or topped <= 0 else round(topped, 4),
    }


def _report(token, *, start, end, group_by):
    return http_util.request_json(
        API_HOST + "/v1/report",
        auth=f"Bearer {token}",
        query={
            "start_date": start.isoformat(),
            "end_date": end.isoformat(),
            "group_by": group_by,
        },
        timeout=20,
    ) or {}


def _fetch_spend(token, remaining_usd):
    """Best-effort /v1/report. Hobby plans get a note, not a hard failure."""
    start, end = balance_spend.period_bounds()
    report_error = None
    day_rows = []
    model_rows = []

    try:
        body = _report(token, start=start, end=end, group_by="day")
        results = body.get("results") if isinstance(body, dict) else None
        if not isinstance(results, list):
            results = body.get("data") if isinstance(body, dict) else None
        for row in results or []:
            if not isinstance(row, dict):
                continue
            day_rows.append({
                "day": row.get("day") or row.get("date"),
                "usd": row.get("total_cost") if "total_cost" in row
                    else row.get("totalCost"),
            })
    except urllib.error.HTTPError as err:
        if err.code in (401, 403, 402):
            report_error = (
                "Spend report needs a Pro or Enterprise AI Gateway plan"
            )
        else:
            report_error = f"report HTTP {err.code}"
    except (OSError, ValueError, TypeError, KeyError) as err:
        report_error = str(err) or "report unavailable"

    try:
        body = _report(token, start=start, end=end, group_by="model")
        results = body.get("results") if isinstance(body, dict) else None
        if not isinstance(results, list):
            results = body.get("data") if isinstance(body, dict) else None
        for row in results or []:
            if not isinstance(row, dict):
                continue
            model = row.get("model")
            model_rows.append({
                "id": model,
                "title": model,
                "usd": row.get("total_cost") if "total_cost" in row
                    else row.get("totalCost"),
                "requests": row.get("request_count") if "request_count" in row
                    else row.get("requestCount"),
            })
    except (OSError, ValueError, TypeError, KeyError, urllib.error.HTTPError):
        pass

    return balance_spend.build_spend(
        remaining_usd=remaining_usd,
        by_day=day_rows,
        by_model=model_rows,
        report_error=report_error,
    )


def fetch_quota(force=False):
    now = time.time()

    token = _token()
    if not token:
        result = {
            **_EMPTY,
            "error": "Connect AI Gateway in Headroom Settings",
            "stale": False,
            "updated_at": int(now),
        }
        if _cache["data"] and _cache["data"].get("ok"):
            return cache_util.keep_stale(
                _cache, now, result["error"], _EMPTY)
        _cache.update(t=now, data=result)
        return result

    if cache_util.fresh(_cache, now, CACHE_TTL_S, FAIL_TTL_S, force):
        return _cache["data"]

    try:
        body = http_util.request_json(
            API_HOST + "/v1/credits",
            auth=f"Bearer {token}",
            timeout=15,
        ) or {}
        balance = _as_float(body.get("balance"))
        if balance is None:
            raise ValueError("credits response missing balance")
        total_used = _as_float(body.get("total_used"))
        bucket = _balance_bucket(balance, total_used)
        spend = _fetch_spend(token, bucket.get("remaining_usd"))
        result = {
            "ok": True,
            "configured": True,
            "error": None,
            "plan": None,
            "balance": bucket,
            "spend": spend,
            "stale": False,
            "updated_at": int(now),
        }
        return cache_util.store(_cache, now, result, disk_name=DISK)
    except urllib.error.HTTPError as err:
        if err.code in (401, 403):
            message = (
                "AI Gateway rejected the key — paste an AI Gateway API key "
                "from the Vercel dashboard"
            )
        else:
            message = f"AI Gateway HTTP {err.code}"
        return cache_util.keep_stale(_cache, now, message, {
            **_EMPTY,
            "configured": True,
            "error": message,
        }, disk_name=DISK)
    except (OSError, ValueError, TypeError) as err:
        return cache_util.keep_stale(_cache, now, str(err) or "AI Gateway error", {
            **_EMPTY,
            "configured": True,
            "error": str(err) or "AI Gateway error",
        }, disk_name=DISK)
