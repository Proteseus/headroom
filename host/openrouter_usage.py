"""OpenRouter prepaid credit balance for Headroom.

Uses a Management API key from, in order: OPENROUTER_API_KEY /
HEADROOM_OPENROUTER_TOKEN, or the Headroom macOS Keychain item. Account
balance is `GET /api/v1/credits` (management key required): remaining is
total_credits − total_usage.

A regular inference key can sometimes read `/credits` too, but Headroom
refuses it on purpose — Settings asks for a management key so the meter is
the account pot, and so a wrong paste is visible instead of a quiet wrong
number. Create one at openrouter.ai/settings/management-keys (not
/settings/keys).

Tokens are never returned in payloads or logs. Stdlib only.
"""

from __future__ import annotations

import os
import time
import urllib.error

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


def _request(path, token, timeout=15):
    return http_util.request_json(
        API_HOST + path,
        auth=f"Bearer {token}",
        timeout=timeout,
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
        result = {
            "ok": True,
            "configured": True,
            "error": None,
            "plan": None,
            "balance": bucket,
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
