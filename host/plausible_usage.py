"""Plausible Analytics site stats for Headroom.

Uses a Stats API key from, in order: PLAUSIBLE_API_KEY / HEADROOM_PLAUSIBLE_TOKEN,
or the Headroom macOS Keychain item. Sites are discovered via GET /api/v1/sites
when the key can list them (Sites API / scopes that include sites:read). Optional
`plausible_sites` in config.json filters that list, or acts as a fallback when
listing is unavailable (common for Stats-only keys).

Tokens are never returned in payloads or logs. Stdlib only.
"""

from __future__ import annotations

import concurrent.futures
import os
import time
import urllib.error
import urllib.parse

import app_config
import cache_util
import http_util
import keychain

DEFAULT_HOST = "https://plausible.io"
CACHE_TTL_S = 2 * 60
FAIL_TTL_S = 45
KEYCHAIN_SERVICE = "com.centaur-labs.headroom.plausible"
KEYCHAIN_ACCOUNT = "access-token"
LIST_PAGE_LIMIT = 100
LIST_MAX_PAGES = 20
DISK = "plausible_stats"

_cache = {"t": 0.0, "data": None}
_EMPTY = {
    "ok": False,
    "configured": False,
    "error": None,
    "sites": [],
    "site_count": 0,
    "visitors_today": 0,
    "realtime": 0,
    "range": "24h",
    "range_label": "24h",
}


def _keychain_token():
    return keychain.read_token(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)


def _token():
    for key in ("PLAUSIBLE_API_KEY", "HEADROOM_PLAUSIBLE_TOKEN"):
        token = os.environ.get(key)
        if token:
            return token.strip()
    return _keychain_token()


def has_token():
    """True when any credential source has a value — not that it works."""
    return bool(_token())


def invalidate():
    """Site filter changed: drop the cache so the next poll re-reads."""
    _cache.update(t=0.0)


def available_sites():
    """Sites the key can see, for the Settings picker.

    Returns `{"sites": [{domain, name}, …], "error": str|None}`. `name` is
    the domain — Plausible has no separate display title.
    """
    token = _token()
    if not token:
        return {"sites": [], "error": "Connect Plausible in Headroom Settings"}
    listed, list_error = _list_sites(token)
    if listed:
        return {
            "sites": [{"domain": d, "name": d} for d in listed],
            "error": None,
        }
    configured = _configured_sites()
    if configured:
        return {
            "sites": [{"domain": d, "name": d} for d in configured],
            "error": None,
        }
    return {
        "sites": [],
        "error": list_error or (
            "Could not list sites — use a Sites API key with sites:read"
        ),
    }


def _api_host():
    return app_config.plausible_host() or DEFAULT_HOST


def _configured_sites():
    out = []
    seen = set()
    for item in app_config.plausible_sites():
        domain = str(item).strip().lower()
        if not domain or domain in seen:
            continue
        seen.add(domain)
        out.append(domain)
    return out


def _request(method, path, token, body=None, query=None, timeout=15):
    return http_util.request_json(
        _api_host() + path,
        auth=f"Bearer {token}",
        query=query,
        json_body=body,
        method=method,
        timeout=timeout,
    )


def _metric_map(payload, metrics):
    """Map a /api/v2/query aggregate response to {metric: value}."""
    results = (payload or {}).get("results") or []
    if not results:
        return {name: None for name in metrics}
    row = results[0] if isinstance(results[0], dict) else {}
    values = row.get("metrics") or []
    out = {}
    for index, name in enumerate(metrics):
        out[name] = values[index] if index < len(values) else None
    return out


def _query(token, site_id, metrics, date_range, timeout=12):
    payload = _request(
        "POST",
        "/api/v2/query",
        token,
        body={
            "site_id": site_id,
            "metrics": list(metrics),
            "date_range": date_range,
        },
        timeout=timeout,
    )
    return _metric_map(payload, metrics)


def _series_spec(range_id):
    """Date range + time dimension for the menubar histogram.

    Multi-day windows stay daily (OpenRouter-shaped). day / 24h use hourly
    buckets so a short primary window still has a readable bar strip.
    """
    if range_id in ("7d", "30d"):
        return range_id, "time:day"
    return range_id, "time:hour"


def _as_int(value):
    if value is None or isinstance(value, bool):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _bucket_key(label, dimension):
    text = str(label or "").strip()
    if not text:
        return None
    if dimension == "time:day":
        return text[:10]
    # Hour labels arrive as "YYYY-MM-DD HH:MM:SS" — keep through the hour.
    if "T" in text:
        return text[:13]
    if " " in text:
        return text[:13]
    return text[:10]


def _fetch_series(token, site_id, range_id, timeout=12):
    """Visitor histogram for one site — filled zeros via time_labels."""
    date_range, dimension = _series_spec(range_id)
    payload = _request(
        "POST",
        "/api/v2/query",
        token,
        body={
            "site_id": site_id,
            "metrics": ["visitors"],
            "date_range": date_range,
            "dimensions": [dimension],
            "include": {"time_labels": True},
        },
        timeout=timeout,
    )
    results = (payload or {}).get("results") or []
    by_bucket = {}
    for row in results:
        if not isinstance(row, dict):
            continue
        dims = row.get("dimensions") or []
        metrics = row.get("metrics") or []
        if not dims:
            continue
        key = _bucket_key(dims[0], dimension)
        visitors = _as_int(metrics[0] if metrics else None)
        if key is None or visitors is None:
            continue
        by_bucket[key] = by_bucket.get(key, 0) + max(0, visitors)

    labels = ((payload or {}).get("meta") or {}).get("time_labels") or []
    keys = []
    seen = set()
    for label in labels:
        key = _bucket_key(label, dimension)
        if key is None or key in seen:
            continue
        seen.add(key)
        keys.append(key)
    if not keys:
        keys = sorted(by_bucket.keys())

    return [
        {"day": key, "visitors": int(by_bucket.get(key, 0))}
        for key in keys
    ]


def _realtime(token, site_id, timeout=8):
    """Current visitors — legacy v1 endpoint still works with Stats keys."""
    payload = _request(
        "GET",
        "/api/v1/stats/realtime/visitors",
        token,
        query={"site_id": site_id},
        timeout=timeout,
    )
    if isinstance(payload, (int, float)):
        return int(payload)
    if isinstance(payload, dict):
        for key in ("visitors", "realtime", "count"):
            if payload.get(key) is not None:
                return int(payload[key])
    return 0


def _domains_from_list_payload(payload):
    rows = []
    if isinstance(payload, dict):
        rows = payload.get("sites") or payload.get("data") or []
    elif isinstance(payload, list):
        rows = payload
    out = []
    for row in rows:
        if isinstance(row, str):
            domain = row.strip().lower()
        elif isinstance(row, dict):
            domain = str(
                row.get("domain") or row.get("site_id") or row.get("id") or ""
            ).strip().lower()
        else:
            continue
        if domain:
            out.append(domain)
    return out


def _list_sites(token):
    """Return (domains, error). Paginate GET /api/v1/sites when available.

    Officially this is the Sites API (Enterprise Sites key). Some keys with
    sites:read also succeed; Stats-only keys typically get 401/403/404.
    """
    out = []
    seen = set()
    after = None
    try:
        for _ in range(LIST_MAX_PAGES):
            query = {"limit": LIST_PAGE_LIMIT}
            if after:
                query["after"] = after
            payload = _request(
                "GET", "/api/v1/sites", token, query=query, timeout=12)
            for domain in _domains_from_list_payload(payload):
                if domain not in seen:
                    seen.add(domain)
                    out.append(domain)
            meta = payload.get("meta") if isinstance(payload, dict) else None
            after = (meta or {}).get("after") if isinstance(meta, dict) else None
            if not after:
                break
    except urllib.error.HTTPError as err:
        if err.code in (401, 403):
            return [], (
                "This API key cannot list sites "
                "(needs Sites API / sites:read)"
            )
        if err.code == 404:
            return [], "Site listing endpoint unavailable for this host"
        return [], f"List sites HTTP {err.code}"
    except (urllib.error.URLError, OSError, ValueError, TypeError) as err:
        return [], str(err) or "list sites failed"
    return out, None


def _resolve_sites(token):
    """Prefer API discovery; config filters or falls back."""
    configured = _configured_sites()
    listed, list_error = _list_sites(token)
    if listed:
        if configured:
            wanted = set(configured)
            filtered = [domain for domain in listed if domain in wanted]
            # Keep any explicitly configured domains the list omitted.
            extras = [domain for domain in configured if domain not in set(filtered)]
            return (
                filtered + extras,
                "api+filter" if extras or len(filtered) != len(listed) else "api",
            )
        return listed, "api"
    if configured:
        return configured, "config"
    return [], list_error or (
        "Could not list sites — use a Sites API key, or set "
        "plausible_sites in ~/.headroom/config.json"
    )


def _dashboard_url(domain):
    host = _api_host()
    return f"{host}/{urllib.parse.quote(domain)}"


def _site_stub(domain, range_id, error=None):
    return {
        "domain": domain,
        "range": range_id,
        "range_label": app_config.plausible_range_label(range_id),
        "visitors_today": None,
        "pageviews_today": None,
        "visitors_7d": None,
        "pageviews_7d": None,
        "bounce_rate_7d": None,
        "visit_duration_7d": None,
        "realtime": 0,
        "by_day": [],
        "dashboard_url": _dashboard_url(domain),
        "error": error,
    }


def _fetch_site(token, domain, range_id):
    """Primary window is configurable; 7d stays as secondary context."""
    primary_metrics = ("visitors", "pageviews")
    rich_metrics = ("visitors", "pageviews", "bounce_rate", "visit_duration")
    error = None
    primary = {name: None for name in primary_metrics}
    week = {name: None for name in rich_metrics}
    realtime = 0
    by_day = []
    try:
        if range_id == "7d":
            week = _query(token, domain, rich_metrics, "7d")
            primary = {key: week.get(key) for key in primary_metrics}
        elif range_id == "30d":
            primary = _query(token, domain, primary_metrics, "30d")
            week = _query(token, domain, rich_metrics, "7d")
        else:
            # day / 24h
            primary = _query(token, domain, primary_metrics, range_id)
            week = _query(token, domain, rich_metrics, "7d")
        realtime = _realtime(token, domain)
        try:
            by_day = _fetch_series(token, domain, range_id)
        except (urllib.error.URLError, OSError, ValueError, TypeError,
                urllib.error.HTTPError):
            # Totals still stand without the strip — same posture as OpenRouter
            # when analytics is partial.
            by_day = []
    except urllib.error.HTTPError as err:
        if err.code in (401, 403):
            raise
        error = f"HTTP {err.code}"
    except (urllib.error.URLError, OSError, ValueError, TypeError) as err:
        error = str(err) or "fetch failed"
    return {
        "domain": domain,
        "range": range_id,
        "range_label": app_config.plausible_range_label(range_id),
        "visitors_today": primary.get("visitors"),
        "pageviews_today": primary.get("pageviews"),
        "visitors_7d": week.get("visitors"),
        "pageviews_7d": week.get("pageviews"),
        "bounce_rate_7d": week.get("bounce_rate"),
        "visit_duration_7d": week.get("visit_duration"),
        "realtime": realtime,
        "by_day": by_day,
        "dashboard_url": _dashboard_url(domain),
        "error": error,
    }


def _sum_int(rows, key):
    total = 0
    for row in rows:
        value = row.get(key)
        if value is None:
            continue
        try:
            total += int(value)
        except (TypeError, ValueError):
            continue
    return total


def fetch_stats(force=False):
    now = time.time()

    token = _token()
    if not token:
        result = {
            **_EMPTY,
            "error": "Connect Plausible in Headroom Settings",
            "stale": False,
            "range": app_config.plausible_range(),
            "range_label": app_config.plausible_range_label(),
            "updated_at": int(now),
        }
        if _cache["data"] and _cache["data"].get("ok"):
            return cache_util.keep_stale(
                _cache, now, result["error"], _EMPTY)
        _cache.update(t=now, data=result)
        return result

    range_id = app_config.plausible_range()
    # A range change invalidates regardless of age — the cached numbers answer
    # a different question than the one now being asked.
    if (
        cache_util.fresh(_cache, now, CACHE_TTL_S, FAIL_TTL_S, force)
        and _cache["data"].get("range") == range_id
    ):
        return _cache["data"]

    sites, source = _resolve_sites(token)
    if not sites:
        result = {
            "ok": False,
            "configured": True,
            "error": source if isinstance(source, str) else (
                "No Plausible sites found"
            ),
            "stale": False,
            "sites": [],
            "site_count": 0,
            "visitors_today": 0,
            "realtime": 0,
            "range": range_id,
            "range_label": app_config.plausible_range_label(range_id),
            "updated_at": int(now),
        }
        _cache.update(t=now, data=result)
        return result

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            futures = {
                pool.submit(_fetch_site, token, domain, range_id): domain
                for domain in sites
            }
            by_domain = {}
            for future, domain in futures.items():
                try:
                    by_domain[domain] = future.result()
                except urllib.error.HTTPError as err:
                    if err.code in (401, 403):
                        raise
                    by_domain[domain] = _site_stub(
                        domain, range_id, error=f"HTTP {err.code}")
                except Exception as err:
                    by_domain[domain] = _site_stub(
                        domain, range_id, error=str(err) or "fetch failed")
            rows = [by_domain[domain] for domain in sites if domain in by_domain]

        # Live traffic first, then busiest in the primary window.
        rows.sort(key=lambda row: (
            -(row.get("realtime") or 0),
            -(row.get("visitors_today") or 0),
            (row.get("domain") or "").casefold(),
        ))
        result = {
            "ok": True,
            "configured": True,
            "error": None,
            "stale": False,
            "sites": rows,
            "site_count": len(rows),
            "visitors_today": _sum_int(rows, "visitors_today"),
            "realtime": _sum_int(rows, "realtime"),
            "range": range_id,
            "range_label": app_config.plausible_range_label(range_id),
            "sites_source": source,
            "updated_at": int(now),
        }
        return cache_util.store(_cache, now, result, disk_name=DISK)
    except urllib.error.HTTPError as error:
        message = "Plausible token rejected" if error.code in (401, 403) else (
            f"Plausible HTTP {error.code}")
        if error.code in (401, 403):
            result = {
                **_EMPTY,
                "configured": True,
                "error": message,
                "stale": False,
                "updated_at": int(now),
            }
            _cache.update(t=now, data=result, err=message)
            return result
        return cache_util.keep_stale(_cache, now, message, {
            **_EMPTY, "configured": True,
        }, disk_name=DISK)
    except Exception as error:
        return cache_util.keep_stale(_cache, now, str(error), {
            **_EMPTY, "configured": True,
        }, disk_name=DISK)
