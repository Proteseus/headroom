"""Windsurf plan quota from the local IDE cache.

Reads `windsurf.settings.cachedPlanInfo` from Windsurf's state.vscdb.
Web/GetPlanStatus (browser session) can come later; local cache is enough to
surface daily/weekly meters when the IDE has been opened.
"""

from __future__ import annotations

import json
import os
import sqlite3
import time

import cache_util
import quota_util

CACHE_TTL_S = 60
FAIL_TTL_S = 20
DISK = "windsurf_quota"
STATE_DB = os.path.expanduser(
    "~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb"
)
CACHE_KEY = "windsurf.settings.cachedPlanInfo"
DAY_WINDOW_S = 24 * 3600
WEEK_WINDOW_S = 7 * 86400

# One cache per account, keyed by account id ("" is the default install).
_cache = {"t": 0.0, "data": None, "err": None}
_caches = {"": _cache}
_EMPTY = {"ok": False, "plan": None, "session": None, "week": None}


def _cache_for(account):
    key = account.id if account else ""
    cache = _caches.get(key)
    if cache is None:
        cache = _caches[key] = {"t": 0.0, "data": None, "err": None}
    return cache


def _state_db(account=None):
    """A second Windsurf login is a second profile's state.vscdb."""
    return account.root if account else STATE_DB


def signed_in():
    return os.path.isfile(STATE_DB)


def _read_cache_blob(account=None):
    path = _state_db(account)
    if not os.path.isfile(path):
        return None
    try:
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            row = con.execute(
                "SELECT value FROM ItemTable WHERE key = ?",
                (CACHE_KEY,),
            ).fetchone()
        finally:
            con.close()
    except sqlite3.Error:
        return None
    if not row or row[0] is None:
        return None
    val = row[0]
    if isinstance(val, bytes):
        val = val.decode("utf-8", errors="replace")
    try:
        return json.loads(val)
    except (json.JSONDecodeError, TypeError):
        return None


def _plan_name(blob):
    plan = blob.get("planName") or blob.get("plan_name")
    if plan:
        return str(plan)
    nested = blob.get("plan")
    if isinstance(nested, dict):
        name = nested.get("name") or nested.get("plan_name")
        return str(name) if name else None
    if isinstance(nested, str):
        return nested
    return None


def _used_from_remaining_field(blob, *keys):
    for key in keys:
        if blob.get(key) is not None:
            return quota_util.remaining_pct_to_used(blob.get(key))
    return None


def _map(blob):
    if not isinstance(blob, dict):
        return None

    daily = _used_from_remaining_field(
        blob,
        "dailyQuotaRemainingPercent",
        "daily_quota_remaining_percent",
    )
    weekly = _used_from_remaining_field(
        blob,
        "weeklyQuotaRemainingPercent",
        "weekly_quota_remaining_percent",
    )

    usage = blob.get("quotaUsage") or blob.get("usage")
    if isinstance(usage, dict):
        if daily is None:
            daily = _used_from_remaining_field(
                usage, "dailyRemainingPercent", "daily_remaining_percent")
        if daily is None:
            daily = quota_util.used_pct(
                usage.get("usedMessages"), usage.get("messages"))
        if weekly is None:
            weekly = _used_from_remaining_field(
                usage, "weeklyRemainingPercent", "weekly_remaining_percent")
        if weekly is None:
            weekly = quota_util.used_pct(
                usage.get("usedFlowActions"), usage.get("flowActions"))

    day_reset = quota_util.resets_from_unix(
        blob.get("dailyQuotaResetAtUnix")
        or blob.get("daily_quota_reset_at_unix")
    )
    week_reset = quota_util.resets_from_unix(
        blob.get("weeklyQuotaResetAtUnix")
        or blob.get("weekly_quota_reset_at_unix")
    )

    ok = daily is not None or weekly is not None
    return {
        "ok": ok,
        "plan": _plan_name(blob),
        "error": None if ok else "Windsurf cache has no quota yet — open the IDE",
        "session": quota_util.pool(daily, day_reset, DAY_WINDOW_S),
        "week": quota_util.pool(weekly, week_reset, WEEK_WINDOW_S),
        "stale": False,
    }


def fetch_quota(force=False, account=None):
    """`account` is an extra login from accounts.py (None = the default one),
    pointing at another profile's state.vscdb."""
    now = time.time()
    cache = _cache_for(account)
    disk_name = account.cache_name if account else DISK
    if cache_util.fresh(cache, now, CACHE_TTL_S, FAIL_TTL_S, force):
        return cache["data"]

    if not os.path.isfile(_state_db(account)):
        return cache_util.keep_stale(
            cache, now, "Windsurf not installed", _EMPTY, disk_name=disk_name)

    blob = _read_cache_blob(account)
    if blob is None:
        return cache_util.keep_stale(
            cache, now,
            "no Windsurf plan cache — sign in to Windsurf",
            _EMPTY, disk_name=disk_name, auth_required=True)

    try:
        out = _map(blob)
        if out and out.get("ok"):
            return cache_util.store(cache, now, out, disk_name=disk_name)
        err = (out or {}).get("error") or "Windsurf quota unavailable"
        return cache_util.keep_stale(
            cache, now, err, _EMPTY, disk_name=disk_name)
    except Exception as exc:  # noqa: BLE001
        return cache_util.keep_stale(
            cache, now, str(exc), _EMPTY, disk_name=disk_name)
