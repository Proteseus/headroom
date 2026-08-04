"""Axiom monitors currently open for Headroom Attention / Activity.

Auth (never returned via /usage), in order:
  AXIOM_TOKEN / HEADROOM_AXIOM_TOKEN
  Keychain item com.centaur-labs.headroom.axiom / access-token
  ~/.axiom.toml / ./.axiom.toml deployment token (first deployment)

Host from axiom_host (default https://api.axiom.co); org id from axiom_org_id
or the toml. Open alerts come from each monitor's recent history (state=open).
Ingest volume and query explorer stay out — this is the break signal only.

Stdlib only. Failures degrade to {ok:false} with keep-stale.
"""

from __future__ import annotations

import concurrent.futures
import os
import time
import urllib.error
import urllib.parse
from datetime import datetime, timedelta, timezone

import app_config
import cache_util
import http_util
import keychain

CACHE_TTL_S = 90
FAIL_TTL_S = 30
KEYCHAIN_SERVICE = "com.centaur-labs.headroom.axiom"
KEYCHAIN_ACCOUNT = "access-token"
KEEP_ALERTS = 8
HISTORY_LOOKBACK_H = 24
HISTORY_CAP_MONITORS = 24
UA = "Headroom/1"
DEFAULT_HOST = "https://api.axiom.co"
DISK = "axiom_monitors"

_cache = {"t": 0.0, "data": None}
_EMPTY = {
    "ok": False,
    "configured": False,
    "error": None,
    "alerts": [],
    "alert_count": 0,
    "host": None,
    "org_id": None,
}


def _keychain_token():
    return keychain.read_token(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)


def _toml_deployment():
    """Best-effort read of the first [deployments.*] block in .axiom.toml."""
    candidates = (
        os.path.join(os.getcwd(), ".axiom.toml"),
        os.path.expanduser("~/.axiom.toml"),
    )
    for path in candidates:
        try:
            with open(path) as handle:
                text = handle.read()
        except OSError:
            continue
        section = None
        fields = {}
        for raw in text.splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                name = line[1:-1].strip()
                if fields.get("token") and section:
                    return fields
                section = name if name.startswith("deployments.") else None
                fields = {}
                continue
            if not section or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key in ("token", "url", "org_id"):
                fields[key] = value
        if fields.get("token"):
            return fields
    return {}


def _token():
    for key in ("HEADROOM_AXIOM_TOKEN", "AXIOM_TOKEN", "AXIOM_API_TOKEN"):
        value = os.environ.get(key)
        if value and value.strip():
            return value.strip()
    token = _keychain_token()
    if token:
        return token
    return (_toml_deployment().get("token") or "").strip() or None


def _org_id():
    configured = (app_config.axiom_org_id() or "").strip()
    if configured:
        return configured
    for key in ("HEADROOM_AXIOM_ORG_ID", "AXIOM_ORG_ID"):
        value = os.environ.get(key)
        if value and value.strip():
            return value.strip()
    return (_toml_deployment().get("org_id") or "").strip() or None


def _api_host():
    configured = (app_config.axiom_host() or "").strip()
    if configured:
        return configured.rstrip("/")
    for key in ("HEADROOM_AXIOM_URL", "AXIOM_URL", "AXIOM_ORG_URL"):
        value = os.environ.get(key)
        if value and value.strip():
            return value.strip().rstrip("/")
    toml_url = (_toml_deployment().get("url") or "").strip()
    if toml_url:
        return toml_url.rstrip("/")
    return DEFAULT_HOST


def has_token():
    return bool(_token())


def invalidate():
    _cache.update(t=0.0)


def _parse_ts(value):
    if not value or not isinstance(value, str):
        return 0.0
    try:
        return datetime.strptime(
            value.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S.%f%z"
        ).timestamp()
    except ValueError:
        try:
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


def _headers(token, org_id):
    headers = {"User-Agent": UA, "Accept": "application/json"}
    if org_id:
        headers["X-Axiom-Org-Id"] = org_id
    return headers


def _get(path, token, org_id, host, query=None, timeout=12):
    return http_util.request_json(
        f"{host}{path}",
        auth=f"Bearer {token}",
        query=query,
        headers=_headers(token, org_id),
        timeout=timeout,
    )


def _ui_host(api_host):
    # api.axiom.co → app.axiom.co; api.eu.axiom.co → app.eu.axiom.co
    host = api_host.rstrip("/")
    if "://" in host:
        scheme, rest = host.split("://", 1)
    else:
        scheme, rest = "https", host
    if rest.startswith("api."):
        rest = "app." + rest[len("api."):]
    return f"{scheme}://{rest}"


def _monitor_open_from_fields(monitor):
    """True/False/None when the list payload already carries status."""
    for key in ("status", "state", "currentState", "current_state",
                "alertState", "alert_state"):
        value = monitor.get(key)
        if isinstance(value, str) and value.strip():
            low = value.strip().lower()
            if low in ("open", "alerting", "firing", "triggered", "active"):
                return True
            if low in ("closed", "ok", "resolved", "inactive", "normal"):
                return False
    return None


def _latest_history_state(token, org_id, host, monitor_id):
    end = datetime.now(timezone.utc)
    start = end - timedelta(hours=HISTORY_LOOKBACK_H)
    try:
        history = _get(
            f"/v2/monitors/{urllib.parse.quote(str(monitor_id))}/history",
            token,
            org_id,
            host,
            query={
                "startTime": start.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "endTime": end.strftime("%Y-%m-%dT%H:%M:%SZ"),
            },
            timeout=10,
        )
    except Exception:
        return None, 0.0
    if not isinstance(history, list) or not history:
        return None, 0.0
    best = None
    best_ts = 0.0
    for row in history:
        if not isinstance(row, dict):
            continue
        ts = _parse_ts(row.get("timestamp"))
        if ts >= best_ts:
            best_ts = ts
            best = row
    if not best:
        return None, 0.0
    return (best.get("state") or "").lower(), best_ts


def _flatten_alert(monitor, opened_at, host):
    mid = monitor.get("id") or monitor.get("name")
    name = monitor.get("name") or f"Monitor {mid}"
    url = f"{_ui_host(host)}/monitors/{urllib.parse.quote(str(mid))}"
    return {
        "id": str(mid),
        "name": name,
        "type": monitor.get("type"),
        "status": "error",
        "created_at": opened_at or 0.0,
        "ago": fmt_ago(opened_at),
        "url": url,
        "description": monitor.get("description"),
    }


def fetch_alerts(force=False):
    now = time.time()
    token = _token()
    org_id = _org_id()
    host = _api_host()

    if not token:
        result = {
            **_EMPTY,
            "host": host,
            "org_id": org_id,
            "error": "Connect Axiom in Headroom Settings",
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
        payload = _get("/v2/monitors", token, org_id, host, timeout=15)
        monitors = payload if isinstance(payload, list) else []
        enabled = [
            row for row in monitors
            if isinstance(row, dict) and not row.get("disabled")
        ]

        open_alerts = []
        need_history = []
        for monitor in enabled:
            known = _monitor_open_from_fields(monitor)
            if known is True:
                opened = _parse_ts(
                    monitor.get("updatedAt") or monitor.get("updated_at")
                ) or now
                open_alerts.append(_flatten_alert(monitor, opened, host))
            elif known is False:
                continue
            else:
                need_history.append(monitor)

        need_history = need_history[:HISTORY_CAP_MONITORS]

        def check(monitor):
            mid = monitor.get("id")
            if not mid:
                return None
            state, ts = _latest_history_state(token, org_id, host, mid)
            if state == "open":
                return _flatten_alert(monitor, ts or now, host)
            return None

        if need_history:
            with concurrent.futures.ThreadPoolExecutor(
                max_workers=min(8, len(need_history))
            ) as pool:
                for row in pool.map(check, need_history):
                    if row:
                        open_alerts.append(row)

        open_alerts.sort(
            key=lambda row: row.get("created_at") or 0, reverse=True)
        open_alerts = open_alerts[:KEEP_ALERTS]
        result = {
            "ok": True,
            "configured": True,
            "error": None,
            "stale": False,
            "host": host,
            "org_id": org_id,
            "alerts": open_alerts,
            "alert_count": len(open_alerts),
            "updated_at": int(now),
        }
        return cache_util.store(_cache, now, result, disk_name=DISK)
    except urllib.error.HTTPError as err:
        if err.code in (401, 403):
            message = "Axiom token rejected (needs monitors|read)"
        else:
            message = f"Axiom HTTP {err.code}"
        return cache_util.keep_stale(_cache, now, message, {
            **_EMPTY, "configured": True, "host": host, "org_id": org_id,
        }, disk_name=DISK)
    except (urllib.error.URLError, OSError, ValueError, TypeError) as err:
        return cache_util.keep_stale(
            _cache, now, str(err) or "Axiom failed",
            {**_EMPTY, "configured": True, "host": host, "org_id": org_id},
            disk_name=DISK,
        )
