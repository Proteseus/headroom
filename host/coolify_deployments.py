"""Coolify live deployments and fresh failures for the Noctalia widget.

Uses a read-only Coolify API token from HEADROOM_COOLIFY_TOKEN or
COOLIFY_API_TOKEN.  The instance URL comes from HEADROOM_COOLIFY_URL or
COOLIFY_URL.  Credentials never enter /usage or logs.

The active endpoint only contains queued/running work.  To keep a failure from
disappearing between polls, the latest deployment for each application is also
checked; a failed latest deployment remains visible for 24 hours, or until a
newer deployment replaces it.
"""

from __future__ import annotations

import concurrent.futures
import os
import time
import urllib.error
import urllib.parse
from datetime import datetime, timezone

import cache_util
import http_util

CACHE_TTL_S = 30
FAIL_TTL_S = 20
FAILURE_MAX_AGE_S = 24 * 60 * 60
MAX_ACTIVE = 8
MAX_FAILURES = 6
# The API defaults to 200 requests/minute. At two 30-second polls per minute,
# active + application list + 40 histories stays below half that budget.
MAX_HISTORY_APPS = 40
DISK = "coolify_deployments"

_cache = {"t": 0.0, "data": None}
_EMPTY = {
    "ok": False,
    "configured": False,
    "error": None,
    "active": [],
    "failures": [],
    "active_count": 0,
    "failure_count": 0,
    "history_truncated": False,
}


def invalidate():
    _cache.update(t=0.0)


def _token():
    for key in ("HEADROOM_COOLIFY_TOKEN", "COOLIFY_API_TOKEN"):
        value = os.environ.get(key)
        if value and value.strip():
            return value.strip()
    return None


def _base_url():
    for key in ("HEADROOM_COOLIFY_URL", "COOLIFY_URL"):
        value = os.environ.get(key)
        if value and value.strip():
            base = value.strip().rstrip("/")
            if base.endswith("/api/v1"):
                base = base[:-7]
            return base
    return None


def configured():
    return bool(_base_url() and _token())


def _get(path, token, query=None, timeout=15):
    return http_util.request_json(
        _base_url() + "/api/v1" + path,
        auth=f"Bearer {token}",
        query=query,
        timeout=timeout,
    )


def _rows(payload):
    if isinstance(payload, list):
        return payload
    if not isinstance(payload, dict):
        return []
    for key in ("deployments", "data", "items"):
        value = payload.get(key)
        if isinstance(value, list):
            return value
    return []


def _timestamp(value):
    if isinstance(value, (int, float)):
        return float(value) / 1000.0 if value > 1e12 else float(value)
    if not isinstance(value, str) or not value.strip():
        return 0.0
    text = value.strip()
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
    except ValueError:
        try:
            return datetime.strptime(
                text[:19], "%Y-%m-%dT%H:%M:%S"
            ).replace(tzinfo=timezone.utc).timestamp()
        except ValueError:
            return 0.0


def _ago(created_at, now=None):
    if not created_at:
        return None
    seconds = max(0, int((time.time() if now is None else now) - created_at))
    if seconds < 60:
        return "just now"
    if seconds < 3600:
        return f"{seconds // 60}m ago"
    if seconds < 86400:
        return f"{seconds // 3600}h ago"
    return f"{seconds // 86400}d ago"


def _flatten(deployment, app=None, now=None):
    app = app or {}
    status = str(deployment.get("status") or "unknown").strip().lower()
    created = _timestamp(
        deployment.get("created_at") or deployment.get("updated_at"))
    commit = str(deployment.get("commit") or "").strip()
    app_id = deployment.get("application_id") or app.get("id")
    app_uuid = app.get("uuid")
    deployment_uuid = deployment.get("deployment_uuid") or deployment.get("uuid")
    return {
        "id": str(deployment_uuid or deployment.get("id") or "|".join([
            str(app_id or app_uuid or "application"),
            commit,
            str(created),
        ])),
        "application_id": str(app_id) if app_id is not None else None,
        "application_uuid": str(app_uuid) if app_uuid else None,
        "application_name": (
            deployment.get("application_name") or app.get("name")
            or "Application"
        ),
        "server_name": deployment.get("server_name"),
        "deployment_uuid": str(deployment_uuid) if deployment_uuid else None,
        "status": status,
        "status_label": {
            "queued": "Queued",
            "in_progress": "Building",
            "finished": "Deployed",
            "failed": "Failed",
            "cancelled-by-user": "Cancelled",
        }.get(status, status.replace("_", " ").capitalize()),
        "commit": commit or None,
        "short_commit": commit[:7] if commit else None,
        "commit_message": deployment.get("commit_message"),
        "created_at": created or None,
        "ago": _ago(created, now=now),
        "url": deployment.get("deployment_url"),
    }


def _application_rows(token):
    apps = _rows(_get("/applications", token, timeout=20))
    apps = [app for app in apps if isinstance(app, dict) and app.get("uuid")]
    apps.sort(
        key=lambda app: _timestamp(app.get("updated_at") or app.get("created_at")),
        reverse=True,
    )
    return apps


def _latest_for_application(app, token):
    uuid = urllib.parse.quote(str(app["uuid"]), safe="")
    payload = _get(
        f"/deployments/applications/{uuid}",
        token,
        # Active retries sit ahead of the terminal result they are replacing.
        # Read enough history to keep the prior failure visible until the
        # retry actually finishes successfully.
        query={"skip": 0, "take": 10},
        timeout=15,
    )
    rows = [row for row in _rows(payload) if isinstance(row, dict)]
    if not rows:
        return None
    rows.sort(
        key=lambda row: _timestamp(row.get("created_at") or row.get("updated_at")),
        reverse=True,
    )
    for deployment in rows:
        status = str(deployment.get("status") or "").strip().lower()
        if status not in ("failed", "finished"):
            continue
        return _flatten(deployment, app=app)
    return None


def _recent_failures(apps, token, now):
    failures = []
    if not apps:
        return failures
    with concurrent.futures.ThreadPoolExecutor(
            max_workers=min(8, len(apps))) as pool:
        futures = [
            pool.submit(_latest_for_application, app, token)
            for app in apps
        ]
        for future in futures:
            try:
                row = future.result()
            except (urllib.error.URLError, urllib.error.HTTPError,
                    OSError, ValueError):
                continue
            if not row or row.get("status") != "failed":
                continue
            created = row.get("created_at")
            if created and now - float(created) > FAILURE_MAX_AGE_S:
                continue
            row["ago"] = _ago(created, now=now)
            failures.append(row)
    failures.sort(key=lambda row: row.get("created_at") or 0, reverse=True)
    return failures


def fetch_deployments(force=False):
    """Return current work plus recent latest failures for /usage."""
    now = time.time()
    if cache_util.fresh(_cache, now, CACHE_TTL_S, FAIL_TTL_S, force):
        return _cache["data"]

    token = _token()
    base = _base_url()
    if not base or not token:
        missing = "Coolify URL" if not base else "Coolify API token"
        return cache_util.keep_stale(
            _cache,
            now,
            f"{missing} not configured",
            _EMPTY,
            disk_name=DISK,
            auth_required=not token,
        )

    try:
        active_payload = _get("/deployments", token, timeout=20)
        active = [
            _flatten(row, now=now)
            for row in _rows(active_payload)
            if isinstance(row, dict)
        ]
        active.sort(key=lambda row: row.get("created_at") or 0, reverse=True)

        apps = _application_rows(token)
        history_truncated = len(apps) > MAX_HISTORY_APPS
        failures = _recent_failures(apps[:MAX_HISTORY_APPS], token, now)

        out = {
            "ok": True,
            "configured": True,
            "error": None,
            "active": active[:MAX_ACTIVE],
            "failures": failures[:MAX_FAILURES],
            "active_count": len(active),
            "failure_count": len(failures),
            "history_truncated": history_truncated,
        }
        return cache_util.store(_cache, now, out, disk_name=DISK)
    except urllib.error.HTTPError as error:
        auth_required = error.code in (401, 403)
        message = (
            "Coolify token rejected"
            if auth_required
            else f"Coolify HTTP {error.code}"
        )
        empty = {**_EMPTY, "configured": True}
        return cache_util.keep_stale(
            _cache, now, message, empty,
            disk_name=DISK, auth_required=auth_required)
    except (urllib.error.URLError, OSError, ValueError) as error:
        empty = {**_EMPTY, "configured": True}
        return cache_util.keep_stale(
            _cache, now, str(error) or "Coolify unavailable", empty,
            disk_name=DISK)
