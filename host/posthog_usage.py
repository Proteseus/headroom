"""PostHog project event stats for Headroom.

Uses a personal API key from, in order: POSTHOG_PERSONAL_API_KEY /
HEADROOM_POSTHOG_TOKEN, or the Headroom macOS Keychain item. Projects are
discovered via GET /api/projects/. Optional `posthog_projects` in config.json
filters that list, or acts as a fallback when listing is unavailable.

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

DEFAULT_HOST = "https://us.posthog.com"
CACHE_TTL_S = 2 * 60
FAIL_TTL_S = 45
KEYCHAIN_SERVICE = "com.centaur-labs.headroom.posthog"
KEYCHAIN_ACCOUNT = "access-token"
LIST_PAGE_LIMIT = 100
LIST_MAX_PAGES = 20
LIVE_WINDOW_SQL = "timestamp >= now() - INTERVAL 5 MINUTE"

_cache = {"t": 0.0, "data": None}
_EMPTY = {
    "ok": False,
    "configured": False,
    "error": None,
    "projects": [],
    "project_count": 0,
    "events_today": 0,
    "users_today": 0,
    "realtime": 0,
    "range": "24h",
    "range_label": "24h",
}


def _keychain_token():
    return keychain.read_token(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)


def _token():
    for key in ("POSTHOG_PERSONAL_API_KEY", "HEADROOM_POSTHOG_TOKEN"):
        token = os.environ.get(key)
        if token:
            return token.strip()
    return _keychain_token()


def has_token():
    """True when any credential source has a value — not that it works."""
    return bool(_token())


def invalidate():
    """Project filter or host changed: drop the cache so the next poll re-reads."""
    _cache.update(t=0.0)


def available_projects():
    """Projects the key can see, for the Settings picker.

    Returns `{"projects": [{id, name}, …], "error": str|None}`.
    """
    token = _token()
    if not token:
        return {"projects": [], "error": "Connect PostHog in Headroom Settings"}
    listed, list_error = _list_projects(token)
    if listed:
        return {
            "projects": [
                {"id": row["id"], "name": row["name"]} for row in listed
            ],
            "error": None,
        }
    configured = _configured_projects()
    if configured:
        return {
            "projects": [
                {"id": pid, "name": pid} for pid in configured
            ],
            "error": None,
        }
    return {
        "projects": [],
        "error": list_error or "Could not list projects",
    }


def _api_host():
    return app_config.posthog_host() or DEFAULT_HOST


def _configured_projects():
    out = []
    seen = set()
    for item in app_config.posthog_projects():
        pid = str(item).strip()
        if not pid or pid in seen:
            continue
        seen.add(pid)
        out.append(pid)
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


def _range_sql(range_id):
    if range_id == "day":
        return "timestamp >= toStartOfDay(now())"
    if range_id == "7d":
        return "timestamp >= now() - INTERVAL 7 DAY"
    if range_id == "30d":
        return "timestamp >= now() - INTERVAL 30 DAY"
    return "timestamp >= now() - INTERVAL 24 HOUR"


def _hogql_row(payload):
    """Pull the first result row from a HogQLQuery response as a tuple."""
    results = (payload or {}).get("results") or []
    if not results:
        return ()
    row = results[0]
    if isinstance(row, (list, tuple)):
        return tuple(row)
    if isinstance(row, dict):
        return tuple(row.values())
    return ()


def _query_counts(token, project_id, where_sql, timeout=12):
    """Return (events, unique_users) for events matching where_sql."""
    payload = _request(
        "POST",
        f"/api/projects/{urllib.parse.quote(str(project_id))}/query/",
        token,
        body={
            "query": {
                "kind": "HogQLQuery",
                "query": (
                    "SELECT count() AS events, "
                    "count(DISTINCT person_id) AS users "
                    f"FROM events WHERE {where_sql}"
                ),
            },
            "name": "headroom-counts",
        },
        timeout=timeout,
    )
    row = _hogql_row(payload)
    events = int(row[0]) if len(row) > 0 and row[0] is not None else 0
    users = int(row[1]) if len(row) > 1 and row[1] is not None else 0
    return events, users


def _query_live(token, project_id, timeout=8):
    """Unique persons with an event in the last five minutes."""
    payload = _request(
        "POST",
        f"/api/projects/{urllib.parse.quote(str(project_id))}/query/",
        token,
        body={
            "query": {
                "kind": "HogQLQuery",
                "query": (
                    "SELECT count(DISTINCT person_id) AS live "
                    f"FROM events WHERE {LIVE_WINDOW_SQL}"
                ),
            },
            "name": "headroom-live",
        },
        timeout=timeout,
    )
    row = _hogql_row(payload)
    if not row or row[0] is None:
        return 0
    return int(row[0])


def _projects_from_list_payload(payload):
    rows = []
    if isinstance(payload, dict):
        rows = payload.get("results") or payload.get("projects") or []
    elif isinstance(payload, list):
        rows = payload
    out = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        pid = row.get("id")
        if pid is None:
            continue
        name = str(row.get("name") or pid).strip() or str(pid)
        out.append({"id": str(pid), "name": name})
    return out


def _list_projects(token):
    """Return ([{id, name}, …], error). Paginate GET /api/projects/."""
    out = []
    seen = set()
    offset = 0
    try:
        for _ in range(LIST_MAX_PAGES):
            payload = _request(
                "GET",
                "/api/projects/",
                token,
                query={"limit": LIST_PAGE_LIMIT, "offset": offset},
                timeout=12,
            )
            batch = _projects_from_list_payload(payload)
            for row in batch:
                if row["id"] not in seen:
                    seen.add(row["id"])
                    out.append(row)
            if isinstance(payload, dict) and payload.get("next"):
                offset += LIST_PAGE_LIMIT
                if not batch:
                    break
                continue
            break
    except urllib.error.HTTPError as err:
        if err.code in (401, 403):
            return [], "PostHog token rejected (needs project:read)"
        return [], f"List projects HTTP {err.code}"
    except (urllib.error.URLError, OSError, ValueError, TypeError) as err:
        return [], str(err) or "list projects failed"
    return out, None


def _resolve_projects(token):
    """Prefer API discovery; config filters or falls back.

    Returns ([{id, name}, …], source_tag_or_error_string).
    """
    configured = _configured_projects()
    listed, list_error = _list_projects(token)
    if listed:
        by_id = {row["id"]: row for row in listed}
        if configured:
            wanted = set(configured)
            filtered = [row for row in listed if row["id"] in wanted]
            extras = [
                {"id": pid, "name": pid}
                for pid in configured
                if pid not in by_id
            ]
            rows = filtered + extras
            tag = (
                "api+filter"
                if extras or len(filtered) != len(listed)
                else "api"
            )
            return rows, tag
        return listed, "api"
    if configured:
        return (
            [{"id": pid, "name": pid} for pid in configured],
            "config",
        )
    return [], list_error or (
        "Could not list projects — check the personal API key, or set "
        "posthog_projects in ~/.headroom/config.json"
    )


def _dashboard_url(project_id):
    host = _api_host()
    return f"{host}/project/{urllib.parse.quote(str(project_id))}"


def _blank_project(project_id, name, range_id, error):
    return {
        "id": str(project_id),
        "name": name or str(project_id),
        "range": range_id,
        "range_label": app_config.posthog_range_label(range_id),
        "events_today": None,
        "users_today": None,
        "events_7d": None,
        "users_7d": None,
        "realtime": 0,
        "dashboard_url": _dashboard_url(project_id),
        "error": error,
    }


def _fetch_project(token, project, range_id):
    """Primary window is configurable; 7d stays as secondary context."""
    pid = project["id"]
    name = project.get("name") or pid
    error = None
    events = users = None
    events_7d = users_7d = None
    realtime = 0
    try:
        if range_id == "7d":
            events, users = _query_counts(token, pid, _range_sql("7d"))
            events_7d, users_7d = events, users
        else:
            events, users = _query_counts(token, pid, _range_sql(range_id))
            events_7d, users_7d = _query_counts(token, pid, _range_sql("7d"))
        realtime = _query_live(token, pid)
    except urllib.error.HTTPError as err:
        if err.code in (401, 403):
            raise
        error = f"HTTP {err.code}"
    except (urllib.error.URLError, OSError, ValueError, TypeError) as err:
        error = str(err) or "fetch failed"
    return {
        "id": pid,
        "name": name,
        "range": range_id,
        "range_label": app_config.posthog_range_label(range_id),
        "events_today": events,
        "users_today": users,
        "events_7d": events_7d,
        "users_7d": users_7d,
        "realtime": realtime,
        "dashboard_url": _dashboard_url(pid),
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
            "error": "Connect PostHog in Headroom Settings",
            "stale": False,
            "range": app_config.posthog_range(),
            "range_label": app_config.posthog_range_label(),
            "updated_at": int(now),
        }
        if _cache["data"] and _cache["data"].get("ok"):
            return cache_util.keep_stale(
                _cache, now, result["error"], _EMPTY)
        _cache.update(t=now, data=result)
        return result

    range_id = app_config.posthog_range()
    # A range change invalidates regardless of age — the cached numbers answer
    # a different question than the one now being asked.
    if (
        cache_util.fresh(_cache, now, CACHE_TTL_S, FAIL_TTL_S, force)
        and _cache["data"].get("range") == range_id
    ):
        return _cache["data"]

    projects, source = _resolve_projects(token)
    if not projects:
        result = {
            "ok": False,
            "configured": True,
            "error": source if isinstance(source, str) else (
                "No PostHog projects found"
            ),
            "stale": False,
            "projects": [],
            "project_count": 0,
            "events_today": 0,
            "users_today": 0,
            "realtime": 0,
            "range": range_id,
            "range_label": app_config.posthog_range_label(range_id),
            "updated_at": int(now),
        }
        _cache.update(t=now, data=result)
        return result

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            futures = {
                pool.submit(_fetch_project, token, project, range_id): project
                for project in projects
            }
            by_id = {}
            for future, project in futures.items():
                pid = project["id"]
                try:
                    by_id[pid] = future.result()
                except urllib.error.HTTPError as err:
                    if err.code in (401, 403):
                        raise
                    by_id[pid] = _blank_project(
                        pid, project.get("name"), range_id, f"HTTP {err.code}")
                except Exception as err:
                    by_id[pid] = _blank_project(
                        pid, project.get("name"), range_id,
                        str(err) or "fetch failed")
            rows = [
                by_id[project["id"]]
                for project in projects
                if project["id"] in by_id
            ]

        # Live traffic first, then busiest in the primary window.
        rows.sort(key=lambda row: (
            -(row.get("realtime") or 0),
            -(row.get("events_today") or 0),
            (row.get("name") or "").casefold(),
        ))
        result = {
            "ok": True,
            "configured": True,
            "error": None,
            "stale": False,
            "projects": rows,
            "project_count": len(rows),
            "events_today": _sum_int(rows, "events_today"),
            "users_today": _sum_int(rows, "users_today"),
            "realtime": _sum_int(rows, "realtime"),
            "range": range_id,
            "range_label": app_config.posthog_range_label(range_id),
            "projects_source": source,
            "updated_at": int(now),
        }
        _cache.update(t=now, data=result, err=None)
        return result
    except urllib.error.HTTPError as error:
        message = "PostHog token rejected" if error.code in (401, 403) else (
            f"PostHog HTTP {error.code}")
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
        })
    except Exception as error:
        return cache_util.keep_stale(_cache, now, str(error), {
            **_EMPTY, "configured": True,
        })
