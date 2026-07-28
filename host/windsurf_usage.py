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

_cache = {"t": 0.0, "data": None, "err": None}
_EMPTY = {"ok": False, "plan": None, "session": None, "week": None}


def signed_in():
    return os.path.isfile(STATE_DB)


def _read_cache_blob():
    if not os.path.isfile(STATE_DB):
        return None
    try:
        con = sqlite3.connect(f"file:{STATE_DB}?mode=ro", uri=True)
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


def fetch_quota(force=False):
    now = time.time()
    if (
        not force
        and _cache["data"] is not None
        and now - _cache["t"] < (FAIL_TTL_S if _cache.get("err") else CACHE_TTL_S)
    ):
        return _cache["data"]

    if not os.path.isfile(STATE_DB):
        return cache_util.keep_stale(
            _cache, now, "Windsurf not installed", _EMPTY, disk_name=DISK)

    blob = _read_cache_blob()
    if blob is None:
        return cache_util.keep_stale(
            _cache, now,
            "no Windsurf plan cache — open Windsurf once",
            _EMPTY, disk_name=DISK)

    try:
        out = _map(blob)
        if out and out.get("ok"):
            cache_util.save_disk(DISK, out)
            _cache.update(t=now, data=out, err=None)
            return out
        err = (out or {}).get("error") or "Windsurf quota unavailable"
        return cache_util.keep_stale(
            _cache, now, err, _EMPTY, disk_name=DISK)
    except Exception as exc:  # noqa: BLE001
        return cache_util.keep_stale(
            _cache, now, str(exc), _EMPTY, disk_name=DISK)
