"""Supabase project portfolio health for Headroom.

Uses a Supabase Management API personal access token from, in order:
SUPABASE_ACCESS_TOKEN, the Headroom macOS Keychain item, or the Supabase CLI
fallback file. Tokens are never returned in payloads or logs.
"""

from __future__ import annotations

import concurrent.futures
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

import cache_util

API = "https://api.supabase.com"
CACHE_TTL_S = 5 * 60
FAIL_TTL_S = 45
KEYCHAIN_SERVICE = "com.mz.headroom.supabase"
KEYCHAIN_ACCOUNT = "access-token"
CLI_TOKEN_PATH = os.path.expanduser("~/.supabase/access-token")
HEALTH_SERVICES = ("auth", "db", "rest", "realtime", "storage")
HEALTHY_WORDS = {
    "active_healthy", "healthy", "ok", "online", "running", "up",
}

_cache = {"t": 0.0, "data": None}
_EMPTY = {
    "ok": False,
    "configured": False,
    "error": None,
    "projects": [],
    "project_count": 0,
    "healthy_count": 0,
    "alert_count": 0,
}


def _keychain_token():
    try:
        return subprocess.check_output(
            [
                "/usr/bin/security", "find-generic-password",
                "-s", KEYCHAIN_SERVICE,
                "-a", KEYCHAIN_ACCOUNT,
                "-w",
            ],
            stderr=subprocess.DEVNULL,
            timeout=4,
            text=True,
        ).strip() or None
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired,
            FileNotFoundError, OSError):
        return None


def _token():
    token = os.environ.get("SUPABASE_ACCESS_TOKEN")
    if token:
        return token.strip()
    token = _keychain_token()
    if token:
        return token
    try:
        with open(CLI_TOKEN_PATH) as handle:
            return handle.read().strip() or None
    except OSError:
        return None


def _get(path, token, query=None, timeout=15):
    url = API + path
    if query:
        url += "?" + urllib.parse.urlencode(query, doseq=True)
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "User-Agent": "Headroom/1",
        },
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode())


def _status_healthy(status):
    return str(status or "").strip().lower() in HEALTHY_WORDS


def _service_rows(payload):
    """Normalize the Management API's evolving health response."""
    rows = []
    source = payload
    if isinstance(payload, dict):
        source = (
            payload.get("services")
            or payload.get("result")
            or payload.get("data")
            or payload
        )
    if isinstance(source, dict):
        source = [
            {"service": name, **(value if isinstance(value, dict)
                                 else {"status": value})}
            for name, value in source.items()
        ]
    if not isinstance(source, list):
        return rows
    for item in source:
        if not isinstance(item, dict):
            continue
        name = (
            item.get("service")
            or item.get("name")
            or item.get("id")
            or item.get("type")
        )
        status = (
            item.get("status")
            or item.get("state")
            or item.get("health")
        )
        healthy = item.get("healthy")
        if healthy is None:
            healthy = _status_healthy(status)
        if name:
            rows.append({
                "name": str(name),
                "status": str(status or ("healthy" if healthy else "unhealthy")),
                "healthy": bool(healthy),
            })
    return rows


def _project_health(project, token):
    ref = project.get("ref") or project.get("id")
    if not ref:
        return [], "missing project ref"
    try:
        payload = _get(
            f"/v1/projects/{urllib.parse.quote(str(ref))}/health",
            token,
            query={
                "services": list(HEALTH_SERVICES),
                "timeout_ms": 3500,
            },
            timeout=8,
        )
        return _service_rows(payload), None
    except urllib.error.HTTPError as error:
        return [], f"HTTP {error.code}"
    except (urllib.error.URLError, OSError, ValueError) as error:
        return [], str(error)


def _flatten_project(project, services, health_error):
    ref = project.get("ref") or project.get("id")
    status = project.get("status")
    unhealthy = [row["name"] for row in services if not row["healthy"]]
    project_healthy = _status_healthy(status)
    if services:
        project_healthy = project_healthy and not unhealthy
    return {
        "ref": ref,
        "name": project.get("name") or ref or "Supabase project",
        "organization_id": project.get("organization_id"),
        "region": project.get("region"),
        "status": status,
        "healthy": project_healthy,
        "services": services,
        "unhealthy_services": unhealthy,
        "health_error": health_error,
        "created_at": project.get("inserted_at") or project.get("created_at"),
        "dashboard_url": (
            f"https://supabase.com/dashboard/project/{ref}" if ref else None
        ),
    }


def fetch_projects(force=False):
    now = time.time()
    if not force and _cache["data"] is not None:
        ttl = CACHE_TTL_S if _cache["data"].get("ok") else FAIL_TTL_S
        if now - _cache["t"] < ttl:
            return _cache["data"]

    token = _token()
    if not token:
        result = {
            "ok": False,
            "configured": False,
            "error": "Connect Supabase in Headroom Settings",
            "projects": [],
            "project_count": 0,
            "healthy_count": 0,
            "alert_count": 0,
            "stale": False,
            "updated_at": int(now),
        }
        # Don't wipe a previously good portfolio if the Keychain briefly fails.
        if _cache["data"] and _cache["data"].get("ok"):
            return cache_util.keep_stale(
                _cache, now, result["error"], _EMPTY)
        _cache.update(t=now, data=result)
        return result

    try:
        raw = _get("/v1/projects", token)
        projects = raw if isinstance(raw, list) else (
            raw.get("projects") or raw.get("data") or [])
        health_by_ref = {}
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            futures = {
                pool.submit(_project_health, project, token):
                project.get("ref") or project.get("id")
                for project in projects
            }
            for future, ref in futures.items():
                try:
                    health_by_ref[ref] = future.result()
                except Exception as error:
                    health_by_ref[ref] = ([], str(error))

        rows = []
        for project in projects:
            ref = project.get("ref") or project.get("id")
            services, health_error = health_by_ref.get(
                ref, ([], "health unavailable"))
            rows.append(_flatten_project(project, services, health_error))
        rows.sort(key=lambda row: (
            0 if not row["healthy"] else 1,
            (row.get("name") or "").casefold(),
        ))
        healthy_count = sum(1 for row in rows if row["healthy"])
        result = {
            "ok": True,
            "configured": True,
            "error": None,
            "stale": False,
            "projects": rows,
            "project_count": len(rows),
            "healthy_count": healthy_count,
            "alert_count": len(rows) - healthy_count,
            "updated_at": int(now),
        }
        _cache.update(t=now, data=result, err=None)
        return result
    except urllib.error.HTTPError as error:
        message = "Supabase token rejected" if error.code in (401, 403) else (
            f"Supabase HTTP {error.code}")
        # Auth rejection is a hard miss — don't keep pretending we're connected.
        if error.code in (401, 403):
            result = {
                "ok": False,
                "configured": True,
                "error": message,
                "stale": False,
                "projects": [],
                "project_count": 0,
                "healthy_count": 0,
                "alert_count": 0,
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
