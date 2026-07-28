"""GitHub Copilot premium / chat quota.

Uses the same GitHub token sources as Actions (`gh auth`, env, Keychain), then
`GET https://api.github.com/copilot_internal/user`. CodexBar-equivalent.
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request

import cache_util
import github_actions
import quota_util

CACHE_TTL_S = 60
FAIL_TTL_S = 20
DISK = "copilot_quota"
USAGE_URL = "https://api.github.com/copilot_internal/user"
UA = "GitHubCopilotChat/0.26.7"
MONTH_WINDOW_S = 30 * 86400

_cache = {"t": 0.0, "data": None, "err": None}
_EMPTY = {"ok": False, "plan": None, "premium": None, "chat": None}


def signed_in():
    return bool(github_actions._token())


def _fetch(token):
    req = urllib.request.Request(
        USAGE_URL,
        headers={
            "Authorization": f"token {token}",
            "Accept": "application/json",
            "Editor-Version": "vscode/1.96.2",
            "Editor-Plugin-Version": "copilot-chat/0.26.7",
            "User-Agent": UA,
            "X-Github-Api-Version": "2025-04-01",
        },
    )
    with urllib.request.urlopen(req, timeout=12) as resp:
        return json.load(resp)


def _snapshot_used_pct(snapshots, key):
    if not isinstance(snapshots, dict):
        return None
    row = snapshots.get(key)
    if not isinstance(row, dict):
        return None
    # API reports percent_remaining; Headroom meters used %.
    if row.get("percent_remaining") is not None:
        return quota_util.remaining_pct_to_used(row["percent_remaining"])
    return quota_util.used_pct(row.get("used"), row.get("limit"))


def _map(blob):
    plan = blob.get("copilot_plan") or blob.get("plan") or blob.get("tier")
    if isinstance(plan, dict):
        plan = plan.get("name") or plan.get("slug")
    snapshots = blob.get("quota_snapshots") or blob.get("quotaSnapshots") or {}
    premium = _snapshot_used_pct(snapshots, "premium_interactions")
    if premium is None:
        premium = _snapshot_used_pct(snapshots, "premiumInteractions")
    chat = _snapshot_used_pct(snapshots, "chat")
    ok = premium is not None or chat is not None
    return {
        "ok": ok,
        "plan": str(plan).replace("_", " ").title() if plan else None,
        "error": None if ok else "no Copilot quota in response",
        "premium": quota_util.pool(premium, None, MONTH_WINDOW_S),
        "chat": quota_util.pool(chat, None, MONTH_WINDOW_S),
        "stale": False,
    }


def fetch_quota(force=False):
    now = time.time()
    if (
        not force
        and _cache["data"] is not None
        and now - _cache["t"] < (FAIL_TTL_S if _cache.get("err") else CACHE_TTL_S)
    ):
        return _cache["data"]

    token = github_actions._token()
    if not token:
        return cache_util.keep_stale(
            _cache, now,
            "Connect GitHub in Headroom Settings (or `gh auth login`)",
            _EMPTY, disk_name=DISK)

    try:
        blob = _fetch(token)
        out = _map(blob)
        if out.get("ok"):
            cache_util.save_disk(DISK, out)
            _cache.update(t=now, data=out, err=None)
            return out
        return cache_util.keep_stale(
            _cache, now, out.get("error") or "Copilot quota unavailable",
            _EMPTY, disk_name=DISK)
    except urllib.error.HTTPError as exc:
        err = f"Copilot HTTP {exc.code}"
        if exc.code in (401, 403):
            err = "GitHub token lacks Copilot access"
        return cache_util.keep_stale(
            _cache, now, err, _EMPTY, disk_name=DISK)
    except Exception as exc:  # noqa: BLE001
        return cache_util.keep_stale(
            _cache, now, str(exc), _EMPTY, disk_name=DISK)
