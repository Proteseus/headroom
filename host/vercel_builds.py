"""Vercel team deployment status for the desk gadget.

Reads the Vercel CLI token + currentTeam from
~/Library/Application Support/com.vercel.cli/{auth,config}.json
(same login the `vercel` CLI uses), refreshes when expired, polls
GET /v6/deployments?teamId=…&limit=…, and flattens recent builds.

Stdlib only. Failures degrade to {ok: false}.
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

import app_config
import http_util
import cache_util

CACHE_TTL_S = 60
FAIL_TTL_S = 20
DEPLOY_LIMIT = 8
API = "https://api.vercel.com/v6/deployments"
TOKEN_URL = "https://api.vercel.com/login/oauth/token"
# Public client id used by the official Vercel CLI (device/OAuth flow).
CLI_CLIENT_ID = "cl_HYyOPBNtFMfHhaUn9L4QPfTZz6TP47bp"
CLI_DIR = os.path.expanduser(
    "~/Library/Application Support/com.vercel.cli")
# Refresh a minute early so a concurrent CLI call doesn't race an expired token.
EXPIRY_SKEW_S = 60

_cache = {"t": 0.0, "data": None}
_EMPTY = {"ok": False, "error": None, "team": None, "deployments": []}


def invalidate():
    """Team filter changed: drop cached deployments so the next poll re-reads."""
    _cache.update(t=0.0)


def _cli_json(name):
    path = os.path.join(CLI_DIR, name)
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def _write_auth(blob):
    path = os.path.join(CLI_DIR, "auth.json")
    raw = json.dumps(blob, indent=2)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(raw)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def _token_fresh(auth):
    token = (auth or {}).get("token")
    if not token:
        return False
    exp = auth.get("expiresAt")
    if exp is None:
        return True  # legacy tokens without expiry
    try:
        exp_s = float(exp)
    except (TypeError, ValueError):
        return True
    # CLI stores unix seconds; tolerate ms just in case.
    if exp_s > 1e12:
        exp_s /= 1000.0
    return time.time() < exp_s - EXPIRY_SKEW_S


def _refresh(auth):
    """Exchange refresh_token for a new access token; persist like the CLI."""
    refresh = (auth or {}).get("refreshToken")
    if not refresh:
        raise RuntimeError("no Vercel refreshToken — run `vercel login`")
    data = http_util.request_json(
        TOKEN_URL,
        form_body={
            "client_id": CLI_CLIENT_ID,
            "grant_type": "refresh_token",
            "refresh_token": refresh,
        },
        method="POST",
        timeout=20,
    )
    access = data.get("access_token")
    if not access:
        raise RuntimeError("Vercel refresh missing access_token")
    auth = dict(auth or {})
    auth["token"] = access
    expires_in = data.get("expires_in")
    if isinstance(expires_in, (int, float)):
        auth["expiresAt"] = int(time.time()) + int(expires_in)
    if data.get("refresh_token"):
        auth["refreshToken"] = data["refresh_token"]
    _write_auth(auth)
    return auth


def _list_teams(token):
    try:
        data = http_util.request_json(
            "https://api.vercel.com/v2/teams", auth=f"Bearer {token}")
        return (data or {}).get("teams") or []
    except (urllib.error.URLError, urllib.error.HTTPError, OSError, ValueError):
        return []


def available_teams():
    """Teams the CLI login can see, for Settings to pick from.

    Returns `[{slug, name}, …]`. Empty when nobody is signed in or the API
    refuses — Settings keeps the typed field in that case.
    """
    try:
        auth = _cli_json("auth.json") or {}
        if not auth.get("token") and not auth.get("refreshToken"):
            return []
        if not _token_fresh(auth):
            auth = _refresh(auth)
        token = auth.get("token")
        if not token:
            return []
        out = []
        seen = set()
        for team in _list_teams(token):
            slug = (team.get("slug") or "").strip()
            if not slug:
                continue
            key = slug.lower()
            if key in seen:
                continue
            seen.add(key)
            out.append({
                "slug": slug,
                "name": (team.get("name") or slug).strip() or slug,
            })
        return out
    except Exception:
        return []


def _resolve_team(token, fallback_id):
    """Pick preferred team slugs from config when available; else CLI currentTeam."""
    teams = _list_teams(token)
    by_slug = {((t.get("slug") or "").lower()): t for t in teams}
    by_name = {((t.get("name") or "").lower()): t for t in teams}
    for slug in app_config.vercel_team_slugs():
        t = by_slug.get(slug) or by_name.get(slug)
        if t and t.get("id"):
            return t["id"], t.get("slug") or t.get("name")
    for t in teams:
        if t.get("id") == fallback_id:
            return fallback_id, t.get("slug") or t.get("name")
    return fallback_id, None


def _auth():
    auth = _cli_json("auth.json") or {}
    cfg = _cli_json("config.json") or {}
    if not auth.get("token") and not auth.get("refreshToken"):
        return None
    if not _token_fresh(auth):
        auth = _refresh(auth)
    team_id, team_slug = _resolve_team(auth["token"], cfg.get("currentTeam"))
    return {
        "token": auth["token"],
        "team_id": team_id,
        "team_slug": team_slug,
        "auth": auth,
    }


def fmt_ago(created_ms):
    """Compact age: minutes under an hour, then whole hours / days.

    Matches git / GitHub activity — no ``2h 15m`` or ``1d 3h``. Activity
    rows only need a glance; ESP32 already coarsens via ``glanceAgo``.
    """
    if created_ms is None:
        return None
    try:
        ts = float(created_ms)
    except (TypeError, ValueError):
        return None
    if ts > 1e12:
        ts /= 1000.0
    ago_s = max(0, int(time.time() - ts))
    if ago_s < 60:
        return f"{ago_s}s"
    if ago_s < 3600:
        return f"{ago_s // 60}m"
    if ago_s < 86400:
        return f"{ago_s // 3600}h"
    return f"{ago_s // 86400}d"


def _state_label(state):
    s = (state or "").upper()
    if s in ("BUILDING", "QUEUED", "INITIALIZING"):
        return "building"
    if s == "READY":
        return "ready"
    if s in ("CANCELED", "CANCELLED"):
        return "canceled"
    if s in ("ERROR", "BLOCKED"):
        return "error"
    return (state or "unknown").lower()


def _meta(dep):
    m = dep.get("meta") or {}
    return (m.get("githubCommitRef")
            or m.get("gitlabCommitRef")
            or m.get("bitbucketCommitRef")
            or m.get("gitBranch")
            or "")


def _flatten(dep):
    name = dep.get("name") or dep.get("project") or "?"
    state = dep.get("readyState") or dep.get("state") or ""
    target = dep.get("target") or ""
    if not target and dep.get("production"):
        target = "production"
    meta = dep.get("meta") or {}
    sha = (meta.get("githubCommitSha")
           or meta.get("gitlabCommitSha")
           or meta.get("bitbucketCommitSha"))
    repo = (meta.get("githubCommitRepo")
            or meta.get("gitlabProjectRepo")
            or meta.get("bitbucketRepoName"))
    return {
        "id": dep.get("uid") or dep.get("id"),
        "project": name,
        "state": state.upper() if state else "UNKNOWN",
        "status": _state_label(state),
        "target": target or None,
        "created_at": dep.get("created") or dep.get("createdAt"),
        "ago": fmt_ago(dep.get("created")),
        "branch": _meta(dep) or None,
        "sha": sha,
        "short_sha": sha[:7] if sha else None,
        "repo": repo,
        "commit_message": (
            meta.get("githubCommitMessage")
            or meta.get("gitlabCommitMessage")
            or meta.get("bitbucketCommitMessage")
        ),
        "error_message": dep.get("errorMessage"),
        "inspector_url": dep.get("inspectorUrl"),
        "url": dep.get("url"),
    }


def _http_get(url, token, team_id):
    q = {"limit": str(DEPLOY_LIMIT)}
    if team_id:
        q["teamId"] = team_id
    return http_util.request_json(
        url, auth=f"Bearer {token}", query=q, timeout=20)


def _team_slug(token, team_id):
    """Best-effort team name for the header; ignore failures."""
    if not team_id:
        return None
    url = f"https://api.vercel.com/v2/teams/{urllib.parse.quote(team_id)}"
    try:
        data = http_util.request_json(
            url, auth=f"Bearer {token}", timeout=10)
        return (data or {}).get("slug") or (data or {}).get("name")
    except (urllib.error.URLError, urllib.error.HTTPError, OSError, ValueError):
        return None


def fetch_deployments(force=False):
    """Return flattened team deployments for /usage."""
    now = time.time()
    if cache_util.fresh(_cache, now, CACHE_TTL_S, FAIL_TTL_S, force):
        return _cache["data"]

    try:
        creds = _auth()
    except Exception as exc:
        return cache_util.keep_stale(_cache, now, str(exc), _EMPTY)

    if not creds:
        return cache_util.keep_stale(
            _cache, now, "no Vercel CLI token — run `vercel login`", _EMPTY)

    try:
        try:
            raw = _http_get(API, creds["token"], creds["team_id"])
        except urllib.error.HTTPError as e:
            # Access token may have been revoked early — refresh once.
            if e.code not in (401, 403):
                raise
            auth = _refresh(creds.get("auth") or _cli_json("auth.json") or {})
            raw = _http_get(API, auth["token"], creds["team_id"])
            creds["token"] = auth["token"]
        deps = raw.get("deployments") or []
        team = (creds.get("team_slug")
                or _team_slug(creds["token"], creds["team_id"])
                or "team")
        out = {
            "ok": True,
            "team": team,
            "error": None,
            "stale": False,
            "deployments": [_flatten(d) for d in deps[:DEPLOY_LIMIT]],
        }
        _cache.update(t=now, data=out, err=None)
        return out
    except urllib.error.HTTPError as e:
        try:
            body = e.read().decode()[:200]
        except Exception:
            body = ""
        return cache_util.keep_stale(
            _cache, now, f"HTTP {e.code} {body}".strip(), _EMPTY)
    except Exception as exc:
        return cache_util.keep_stale(_cache, now, str(exc), _EMPTY)
