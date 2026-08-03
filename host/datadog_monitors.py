"""Datadog monitors in Alert / Warn for Headroom Attention / Activity.

Auth (never returned via /usage), in order:
  DD_API_KEY + DD_APP_KEY / HEADROOM_DATADOG_* 
  Keychain com.centaur-labs.headroom.datadog accounts api-key + app-key

Site from datadog_site in config.json (default datadoghq.com). Only monitors
whose overall_state is Alert light Attention as critical; Warn is a quieter
reason. Full APM / host maps stay out — this is the break signal only.

Stdlib only. Failures degrade to {ok:false} with keep-stale.
"""

from __future__ import annotations

import os
import time
import urllib.error

import app_config
import cache_util
import http_util
import keychain

CACHE_TTL_S = 90
FAIL_TTL_S = 30
KEYCHAIN_SERVICE = "com.centaur-labs.headroom.datadog"
KEYCHAIN_API = "api-key"
KEYCHAIN_APP = "app-key"
KEEP_MONITORS = 8
UA = "Headroom/1"

_cache = {"t": 0.0, "data": None}
_EMPTY = {
    "ok": False,
    "configured": False,
    "error": None,
    "monitors": [],
    "alert_count": 0,
    "warn_count": 0,
    "site": None,
}


def _keychain(account):
    return keychain.read_token(KEYCHAIN_SERVICE, account)


def _api_key():
    for key in ("HEADROOM_DATADOG_API_KEY", "DD_API_KEY"):
        value = os.environ.get(key)
        if value and value.strip():
            return value.strip()
    return _keychain(KEYCHAIN_API)


def _app_key():
    for key in ("HEADROOM_DATADOG_APP_KEY", "DD_APP_KEY",
                "DD_APPLICATION_KEY"):
        value = os.environ.get(key)
        if value and value.strip():
            return value.strip()
    return _keychain(KEYCHAIN_APP)


def has_keys():
    return bool(_api_key() and _app_key())


def invalidate():
    _cache.update(t=0.0)


def _parse_ts(value):
    if isinstance(value, (int, float)):
        # Datadog sometimes returns ms.
        ts = float(value)
        return ts / 1000.0 if ts > 1e12 else ts
    if not value or not isinstance(value, str):
        return 0.0
    try:
        from datetime import datetime
        return datetime.strptime(
            value.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S%z"
        ).timestamp()
    except ValueError:
        return 0.0


def fmt_ago(unix_ts):
    if not unix_ts:
        return None
    ago_s = max(0, int(time.time() - float(unix_ts)))
    if ago_s < 60:
        return f"{ago_s}s"
    if ago_s < 3600:
        return f"{ago_s // 60}m"
    if ago_s < 86400:
        return f"{ago_s // 3600}h"
    return f"{ago_s // 86400}d"


def _api_host():
    site = (app_config.datadog_site() or "datadoghq.com").strip().lstrip(".")
    site = site.removeprefix("https://").removeprefix("http://")
    site = site.removeprefix("api.").removeprefix("app.")
    site = site.split("/")[0] or "datadoghq.com"
    return f"https://api.{site}", site


def _app_host(site):
    return f"https://app.{site}"


def _flatten_monitor(row, site):
    state = (row.get("overall_state") or row.get("overallState") or "").strip()
    state_l = state.lower()
    if state_l == "alert":
        status = "error"
    elif state_l == "warn":
        status = "error"
    else:
        status = state_l or "unknown"
    mid = row.get("id")
    name = row.get("name") or f"Monitor {mid}"
    modified = _parse_ts(
        row.get("overall_state_modified")
        or row.get("modified")
        or row.get("created")
    )
    url = None
    if mid is not None:
        url = f"{_app_host(site)}/monitors/{mid}"
    return {
        "id": str(mid if mid is not None else name),
        "name": name,
        "overall_state": state,
        "status": status,
        "type": row.get("type"),
        "created_at": modified,
        "ago": fmt_ago(modified),
        "url": url,
        "site": site,
    }


def fetch_monitors(force=False):
    now = time.time()
    api_key = _api_key()
    app_key = _app_key()
    api_base, site = _api_host()

    if not api_key or not app_key:
        result = {
            **_EMPTY,
            "site": site,
            "error": "Connect Datadog in Headroom Settings (API + App key)",
            "stale": False,
            "updated_at": int(now),
        }
        if _cache["data"] and _cache["data"].get("ok"):
            return cache_util.keep_stale(
                _cache, now, result["error"], _EMPTY)
        _cache.update(t=now, data=result)
        return result

    if not cache_util.fresh(_cache, now, CACHE_TTL_S, FAIL_TTL_S, force):
        return _cache["data"]

    try:
        payload = http_util.request_json(
            f"{api_base}/api/v1/monitor",
            query={"group_states": "alert,warn", "with_downtimes": "true"},
            headers={
                "DD-API-KEY": api_key,
                "DD-APPLICATION-KEY": app_key,
                "Accept": "application/json",
                "User-Agent": UA,
            },
            timeout=15,
        )
        rows = payload if isinstance(payload, list) else []
        monitors = []
        for row in rows:
            if not isinstance(row, dict):
                continue
            flat = _flatten_monitor(row, site)
            state = (flat.get("overall_state") or "").lower()
            if state not in ("alert", "warn"):
                continue
            monitors.append(flat)
        monitors.sort(key=lambda row: row.get("created_at") or 0, reverse=True)
        monitors = monitors[:KEEP_MONITORS]
        alert_count = sum(
            1 for row in monitors
            if (row.get("overall_state") or "").lower() == "alert"
        )
        warn_count = sum(
            1 for row in monitors
            if (row.get("overall_state") or "").lower() == "warn"
        )
        result = {
            "ok": True,
            "configured": True,
            "error": None,
            "stale": False,
            "site": site,
            "monitors": monitors,
            "alert_count": alert_count,
            "warn_count": warn_count,
            "updated_at": int(now),
        }
        _cache.update(t=now, data=result)
        return result
    except urllib.error.HTTPError as err:
        if err.code in (401, 403):
            message = "Datadog keys rejected"
        else:
            message = f"Datadog HTTP {err.code}"
        return cache_util.keep_stale(_cache, now, message, {
            **_EMPTY, "configured": True, "site": site,
        })
    except (urllib.error.URLError, OSError, ValueError, TypeError) as err:
        return cache_util.keep_stale(
            _cache, now, str(err) or "Datadog failed",
            {**_EMPTY, "configured": True, "site": site},
        )
