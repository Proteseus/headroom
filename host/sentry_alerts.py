"""Sentry unresolved issues for Headroom Attention / Activity.

Auth (never returned via /usage), in order:
  SENTRY_AUTH_TOKEN / HEADROOM_SENTRY_TOKEN
  Keychain item com.centaur-labs.headroom.sentry / access-token

Org slug from sentry_org in config.json (required once a token is set).
Only issues with lastSeen inside ATTENTION_MAX_AGE_S light Attention —
unresolved debt from last month stays out of the pip.

Stdlib only. Failures degrade to {ok:false} with keep-stale.
"""

from __future__ import annotations

import os
import time
import urllib.error
import urllib.parse

import app_config
import cache_util
import http_util
import keychain

API = "https://sentry.io/api/0"
CACHE_TTL_S = 90
FAIL_TTL_S = 30
KEYCHAIN_SERVICE = "com.centaur-labs.headroom.sentry"
KEYCHAIN_ACCOUNT = "access-token"
KEEP_ISSUES = 8
ATTENTION_MAX_AGE_S = 24 * 3600
UA = "Headroom/1"
DISK = "sentry_alerts"

_cache = {"t": 0.0, "data": None}
_EMPTY = {
    "ok": False,
    "configured": False,
    "error": None,
    "issues": [],
    "alert_count": 0,
    "org": None,
}


def _keychain_token():
    return keychain.read_token(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)


def _token():
    for key in ("HEADROOM_SENTRY_TOKEN", "SENTRY_AUTH_TOKEN"):
        value = os.environ.get(key)
        if value and value.strip():
            return value.strip()
    return _keychain_token()


def has_token():
    return bool(_token())


def invalidate():
    _cache.update(t=0.0)


def _parse_ts(value):
    if not value or not isinstance(value, str):
        return 0.0
    try:
        from datetime import datetime
        return datetime.strptime(
            value.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S%z"
        ).timestamp()
    except ValueError:
        try:
            from datetime import datetime
            return datetime.strptime(
                value[:19] + "+0000", "%Y-%m-%dT%H:%M:%S%z"
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


def _get(path, token, query=None, timeout=12):
    return http_util.request_json(
        API + path,
        auth=f"Bearer {token}",
        query=query,
        user_agent=UA,
        timeout=timeout,
    )


def _project_slug(issue):
    project = issue.get("project") or {}
    if isinstance(project, dict):
        return project.get("slug") or project.get("name")
    return None


def _flatten_issue(issue, org):
    last_seen = _parse_ts(issue.get("lastSeen") or issue.get("last_seen"))
    first_seen = _parse_ts(issue.get("firstSeen") or issue.get("first_seen"))
    title = issue.get("title") or issue.get("culprit") or "Issue"
    project = _project_slug(issue)
    short_id = issue.get("shortId") or issue.get("short_id")
    issue_id = str(issue.get("id") or short_id or title)
    permalink = issue.get("permalink")
    if not permalink and org and short_id:
        permalink = f"https://sentry.io/organizations/{org}/issues/{issue_id}/"
    level = (issue.get("level") or "error").lower()
    return {
        "id": issue_id,
        "title": title,
        "project": project,
        "short_id": short_id,
        "level": level,
        "status": "error",
        "count": issue.get("count"),
        "user_count": issue.get("userCount") or issue.get("user_count"),
        "last_seen": last_seen,
        "first_seen": first_seen,
        "ago": fmt_ago(last_seen),
        "url": permalink,
        "org": org,
    }


def _is_fresh(issue, now=None):
    now = now if now is not None else time.time()
    last_seen = issue.get("last_seen") or 0
    try:
        return (now - float(last_seen)) <= ATTENTION_MAX_AGE_S
    except (TypeError, ValueError):
        return False


def attention_alert_count(payload, now=None):
    """Fresh unresolved issues only — aged debt does not light the pip."""
    now = now if now is not None else time.time()
    return sum(
        1 for row in (payload.get("issues") or [])
        if _is_fresh(row, now)
    )


def _resolve_org(token):
    org = (app_config.sentry_org() or "").strip()
    if org:
        return org, None
    try:
        orgs = _get("/organizations/", token, query={"member": "1"}, timeout=10)
    except urllib.error.HTTPError as err:
        if err.code in (401, 403):
            return None, "Sentry token rejected"
        return None, f"List orgs HTTP {err.code}"
    except (urllib.error.URLError, OSError, ValueError, TypeError) as err:
        return None, str(err) or "list orgs failed"
    if not isinstance(orgs, list) or not orgs:
        return None, "Set sentry_org in Settings (no org on this token)"
    slug = (orgs[0] or {}).get("slug")
    if not slug:
        return None, "Set sentry_org in Settings"
    return str(slug), None


def fetch_issues(force=False):
    now = time.time()
    token = _token()
    if not token:
        result = {
            **_EMPTY,
            "error": "Connect Sentry in Headroom Settings",
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
        org, org_error = _resolve_org(token)
        if not org:
            result = {
                **_EMPTY,
                "configured": True,
                "error": org_error or "Set sentry_org in Settings",
                "stale": False,
                "updated_at": int(now),
            }
            _cache.update(t=now, data=result)
            return result

        payload = _get(
            f"/organizations/{urllib.parse.quote(org)}/issues/",
            token,
            query={
                "query": "is:unresolved",
                "sort": "date",
                "limit": str(KEEP_ISSUES * 2),
                "statsPeriod": "24h",
            },
            timeout=15,
        )
        rows = payload if isinstance(payload, list) else []
        issues = [
            _flatten_issue(row, org)
            for row in rows
            if isinstance(row, dict)
        ]
        # Prefer recently seen; keep a short feed either way.
        issues.sort(key=lambda row: row.get("last_seen") or 0, reverse=True)
        issues = issues[:KEEP_ISSUES]
        alert_count = sum(1 for row in issues if _is_fresh(row, now))
        result = {
            "ok": True,
            "configured": True,
            "error": None,
            "stale": False,
            "org": org,
            "issues": issues,
            "alert_count": alert_count,
            "updated_at": int(now),
        }
        return cache_util.store(_cache, now, result, disk_name=DISK)
    except urllib.error.HTTPError as err:
        if err.code in (401, 403):
            message = "Sentry token rejected (needs event:read)"
        else:
            message = f"Sentry HTTP {err.code}"
        return cache_util.keep_stale(_cache, now, message, {
            **_EMPTY, "configured": True,
        }, disk_name=DISK)
    except (urllib.error.URLError, OSError, ValueError, TypeError) as err:
        return cache_util.keep_stale(_cache, now, str(err) or "Sentry failed", {
            **_EMPTY, "configured": True,
        }, disk_name=DISK)
