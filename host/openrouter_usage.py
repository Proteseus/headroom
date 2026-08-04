"""OpenRouter prepaid credit balance + spend leaf for Headroom.

Uses a Management API key from, in order: OPENROUTER_API_KEY /
HEADROOM_OPENROUTER_TOKEN, or the Headroom macOS Keychain item.

- `GET /api/v1/credits` — account pot (total_credits − total_usage)
- `GET /api/v1/key` — refuse inference keys (`is_management_key`)
- `POST /api/v1/analytics/query` — daily spend + top models (beta)
- `GET /api/v1/keys` — per-key daily/weekly/monthly usage

A regular inference key can sometimes read `/credits` too, but Headroom
refuses it on purpose. Create one at openrouter.ai/settings/management-keys.

Tokens are never returned in payloads or logs. Stdlib only.
"""

from __future__ import annotations

import os
import time
import urllib.error
from datetime import datetime, timezone

import balance_spend
import cache_util
import http_util
import keychain

API_HOST = "https://openrouter.ai"
CACHE_TTL_S = 2 * 60
FAIL_TTL_S = 45
KEYCHAIN_SERVICE = "com.centaur-labs.headroom.openrouter"
KEYCHAIN_ACCOUNT = "access-token"

MANAGEMENT_KEYS_URL = "openrouter.ai/settings/management-keys"
WRONG_KEY_TYPE = (
    "Inference key — paste a Management API key from "
    + MANAGEMENT_KEYS_URL
)
REJECTED_KEY = (
    "OpenRouter rejected the key — use a Management API key "
    f"({MANAGEMENT_KEYS_URL})"
)

_cache = {"t": 0.0, "data": None}
_EMPTY = {
    "ok": False,
    "configured": False,
    "error": None,
    "plan": None,
    "balance": None,
    "spend": None,
}


class WrongKeyType(ValueError):
    """Stored credential is an inference key, not a Management API key."""


def _keychain_token():
    return keychain.read_token(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)


def _token():
    for key in ("OPENROUTER_API_KEY", "HEADROOM_OPENROUTER_TOKEN"):
        token = os.environ.get(key)
        if token:
            return token.strip()
    return _keychain_token()


def has_token():
    """True when any credential source has a value — not that it works."""
    return bool(_token())


def invalidate():
    _cache.update(t=0.0)


def _request(path, token, timeout=15, json_body=None, method=None):
    return http_util.request_json(
        API_HOST + path,
        auth=f"Bearer {token}",
        timeout=timeout,
        json_body=json_body,
        method=method,
    )


def _require_management_key(token):
    """Refuse inference keys even when `/credits` would answer them."""
    info = _request("/api/v1/key", token)
    data = (info or {}).get("data") or {}
    if data.get("is_management_key") is False:
        raise WrongKeyType(WRONG_KEY_TYPE)


def _balance_bucket(total_credits, total_usage):
    """Normalize OpenRouter lifetime totals into the balance meter shape."""
    credits = float(total_credits)
    usage = float(total_usage)
    remaining = max(0.0, credits - usage)
    return {
        "remaining_usd": round(remaining, 4),
        "used_usd": round(max(0.0, usage), 4),
        # Lifetime purchased is the only denominator OpenRouter exposes; it
        # is not "last top-up", but it is an honest pot size for a depletion
        # bar until a finer reading exists.
        "topped_up_usd": round(credits, 4) if credits > 0 else None,
    }


def _iso(day):
    return datetime(day.year, day.month, day.day, tzinfo=timezone.utc).strftime(
        "%Y-%m-%dT00:00:00Z"
    )


def _analytics_rows(token, *, metrics, dimensions=None, granularity=None,
                    limit=None, start=None, end=None):
    body = {
        "metrics": list(metrics),
        "time_range": {"start": _iso(start), "end": _iso(end)},
    }
    if dimensions:
        body["dimensions"] = list(dimensions)
    if granularity:
        body["granularity"] = granularity
    if limit is not None:
        body["limit"] = int(limit)
        body["order_by"] = {"field": metrics[0], "direction": "desc"}
    raw = _request(
        "/api/v1/analytics/query", token,
        json_body=body, method="POST", timeout=20,
    ) or {}
    data = raw.get("data") if isinstance(raw, dict) else None
    if isinstance(data, dict):
        rows = data.get("data")
        if isinstance(rows, list):
            return rows
    if isinstance(data, list):
        return data
    return []


def _day_field(row):
    for key, value in (row or {}).items():
        if key.startswith("date__") or key.startswith("created_at__"):
            return value
        if key in ("day", "date"):
            return value
    return None


def _fetch_spend(token, remaining_usd):
    """Best-effort analytics + keys. Balance still lands if these fail."""
    from datetime import timedelta
    start, end = balance_spend.period_bounds()
    # End exclusive on the analytics API — push one day past today.
    end_for_api = end + timedelta(days=1)

    report_error = None
    day_rows = []
    model_rows = []
    try:
        raw_days = _analytics_rows(
            token,
            metrics=["total_usage"],
            granularity="day",
            start=start,
            end=end_for_api,
        )
        for row in raw_days:
            if not isinstance(row, dict):
                continue
            day_rows.append({
                "day": _day_field(row),
                "usd": row.get("total_usage"),
            })
    except (OSError, ValueError, TypeError, KeyError, urllib.error.HTTPError) as err:
        report_error = str(err) or "analytics unavailable"

    try:
        raw_models = _analytics_rows(
            token,
            metrics=["total_usage", "request_count"],
            dimensions=["model"],
            limit=balance_spend.TOP_MODELS,
            start=start,
            end=end_for_api,
        )
        for row in raw_models:
            if not isinstance(row, dict):
                continue
            model_rows.append({
                "id": row.get("model"),
                "title": row.get("model"),
                "usd": row.get("total_usage"),
                "requests": row.get("request_count"),
            })
    except (OSError, ValueError, TypeError, KeyError, urllib.error.HTTPError):
        pass

    key_rows = []
    try:
        keys_body = _request("/api/v1/keys", token) or {}
        keys = keys_body.get("data") if isinstance(keys_body, dict) else None
        if isinstance(keys, list):
            for row in keys:
                if not isinstance(row, dict):
                    continue
                key_rows.append({
                    "name": row.get("name") or row.get("label"),
                    "usage_daily": row.get("usage_daily"),
                    "usage_weekly": row.get("usage_weekly"),
                    "usage_monthly": row.get("usage_monthly"),
                })
    except (OSError, ValueError, TypeError, KeyError, urllib.error.HTTPError):
        pass

    return balance_spend.build_spend(
        remaining_usd=remaining_usd,
        by_day=day_rows,
        by_model=model_rows,
        by_key=key_rows,
        report_error=report_error,
    )


def fetch_quota(force=False):
    now = time.time()

    token = _token()
    if not token:
        result = {
            **_EMPTY,
            "error": "Connect OpenRouter in Headroom Settings",
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
        _require_management_key(token)
        body = _request("/api/v1/credits", token)
        data = (body or {}).get("data") or {}
        if "total_credits" not in data or "total_usage" not in data:
            raise ValueError("credits response missing totals")
        bucket = _balance_bucket(data["total_credits"], data["total_usage"])
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
        _cache.update(t=now, data=result)
        return result
    except WrongKeyType as err:
        message = str(err) or WRONG_KEY_TYPE
        return cache_util.keep_stale(_cache, now, message, {
            **_EMPTY,
            "configured": True,
            "error": message,
        })
    except urllib.error.HTTPError as err:
        if err.code in (401, 403):
            message = REJECTED_KEY
        else:
            message = f"OpenRouter HTTP {err.code}"
        return cache_util.keep_stale(_cache, now, message, {
            **_EMPTY,
            "configured": True,
            "error": message,
        })
    except (OSError, ValueError, TypeError, KeyError) as err:
        return cache_util.keep_stale(_cache, now, str(err) or "OpenRouter error", {
            **_EMPTY,
            "configured": True,
            "error": str(err) or "OpenRouter error",
        })
