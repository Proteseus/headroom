"""Cursor plan-usage fetcher (Total + Auto + API pools).

Reads the signed-in Cursor JWT from
`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
(`cursorAuth/accessToken`), calls Connect RPC
`POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`,
and returns Auto / API utilization plus billing-cycle reset time.

Stdlib only. Failures degrade to an empty quota dict.
"""

from __future__ import annotations

import json
import os
import sqlite3
import time
import urllib.error
import urllib.request

import cache_util
import oauth_usage

USAGE_URL = (
    "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
)
UA = "Mozilla/5.0 Cursor"
CACHE_TTL_S = 60
FAIL_TTL_S = 20
PACE_MIN_ELAPSED_FRAC = 0.03

STATE_DB = os.path.expanduser(
    "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
)

_cache = {"t": 0.0, "data": None, "err": None}


def _state_value(key):
    try:
        con = sqlite3.connect(f"file:{STATE_DB}?mode=ro", uri=True)
        try:
            row = con.execute(
                "SELECT value FROM ItemTable WHERE key = ?", (key,)
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
    return str(val)


def _read_token():
    tok = _state_value("cursorAuth/accessToken")
    return tok.strip() if tok else None


def _read_plan():
    raw = _state_value("cursorAuth/stripeMembershipType")
    return _prettify_plan(raw)


def _prettify_plan(raw):
    if not raw:
        return None
    s = str(raw).strip().lower().replace("_", " ").replace("-", " ")
    aliases = {
        "pro": "Pro",
        "pro plus": "Pro+",
        "proplus": "Pro+",
        "ultra": "Ultra",
        "business": "Business",
        "enterprise": "Enterprise",
        "free": "Free",
        "hobby": "Hobby",
    }
    if s in aliases:
        return aliases[s]
    return s[:1].upper() + s[1:] if s else None


def _ms_to_unix(v):
    if v is None:
        return None
    try:
        ts = float(v)
    except (TypeError, ValueError):
        return None
    if ts > 1e12:
        ts /= 1000.0
    return ts


def _pool(pct, resets_in_s, window_s):
    if pct is None:
        return None
    return {
        "pct": round(float(pct), 1),
        "resets_in_s": int(resets_in_s) if resets_in_s is not None else None,
        "resets_in": oauth_usage.fmt_resets(resets_in_s),
        "window_s": int(window_s) if window_s else None,
    }


def _total_pct(plan_usage, auto, api):
    """Resolve Cursor's Total headline using the dashboard's precedence."""
    direct = plan_usage.get("totalPercentUsed")
    if direct is not None:
        return direct
    if auto and api:
        return (float(auto["pct"]) + float(api["pct"])) / 2.0
    if api:
        return api["pct"]
    if auto:
        return auto["pct"]
    used = plan_usage.get("used")
    limit = plan_usage.get("limit")
    try:
        if used is not None and limit is not None and float(limit) > 0:
            return 100.0 * float(used) / float(limit)
    except (TypeError, ValueError):
        pass
    return None


def _pace(pool):
    """Even-consumption pace across the billing cycle (CodexBar-style)."""
    if not pool:
        return None
    pct = pool.get("pct")
    window_s = pool.get("window_s")
    resets_in = pool.get("resets_in_s")
    if pct is None or not window_s or resets_in is None:
        return None
    elapsed = max(0, int(window_s) - int(resets_in))
    if window_s <= 0 or elapsed / window_s < PACE_MIN_ELAPSED_FRAC:
        return None
    expected = 100.0 * elapsed / window_s
    delta = float(pct) - expected
    out = {
        "expected_pct": round(expected, 1),
        "delta_pct": round(abs(delta), 1),
        "in_deficit": delta > 0.5,
        "in_reserve": delta < -0.5,
    }
    if out["in_deficit"]:
        out["label"] = f"{out['delta_pct']:.0f}% in deficit"
    elif out["in_reserve"]:
        out["label"] = f"{out['delta_pct']:.0f}% in reserve"
    else:
        out["label"] = "On pace"
    return out


def _on_demand(spend):
    if not isinstance(spend, dict):
        return None
    limit = spend.get("individualLimit")
    remaining = spend.get("individualRemaining")
    if limit is None and remaining is None:
        return None
    # Values are cents.
    def dollars(cents):
        if cents is None:
            return None
        try:
            return round(float(cents) / 100.0, 2)
        except (TypeError, ValueError):
            return None

    rem_d = dollars(remaining)
    lim_d = dollars(limit)
    used_d = None
    if rem_d is not None and lim_d is not None:
        used_d = round(max(0.0, lim_d - rem_d), 2)
    label = None
    if rem_d is not None and lim_d is not None:
        label = f"${rem_d:.0f} / ${lim_d:.0f} on-demand"
    elif rem_d is not None:
        label = f"${rem_d:.0f} on-demand left"
    return {
        "limit_cents": int(limit) if isinstance(limit, (int, float)) else None,
        "remaining_cents": (
            int(remaining) if isinstance(remaining, (int, float)) else None
        ),
        "limit_usd": lim_d,
        "remaining_usd": rem_d,
        "used_usd": used_d,
        "label": label,
    }


def _plan_spend(plan_usage):
    """Included-plan spend from GetCurrentPeriodUsage.planUsage (cents)."""
    if not isinstance(plan_usage, dict):
        return None

    def cents_to_usd(value):
        if value is None:
            return None
        try:
            return round(float(value) / 100.0, 2)
        except (TypeError, ValueError):
            return None

    used = cents_to_usd(
        plan_usage.get("totalSpend")
        if plan_usage.get("totalSpend") is not None
        else plan_usage.get("includedSpend")
    )
    included = cents_to_usd(plan_usage.get("includedSpend"))
    limit = cents_to_usd(plan_usage.get("limit"))
    remaining = cents_to_usd(plan_usage.get("remaining"))
    if used is None and limit is None and remaining is None:
        return None
    label = None
    if used is not None and limit is not None:
        label = f"${used:.0f} / ${limit:.0f}"
    elif used is not None:
        label = f"${used:.0f} used"
    return {
        "used_usd": used,
        "included_usd": included,
        "limit_usd": limit,
        "remaining_usd": remaining,
        "label": label,
    }


def _http_usage(token):
    body = b"{}"
    req = urllib.request.Request(
        USAGE_URL,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Connect-Protocol-Version": "1",
            "User-Agent": UA,
        },
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        return resp.getcode(), json.loads(resp.read().decode())


def parse_usage(body, plan=None):
    """Map GetCurrentPeriodUsage → quota dict for /usage."""
    plan_usage = (body or {}).get("planUsage") or {}
    start_s = _ms_to_unix((body or {}).get("billingCycleStart"))
    end_s = _ms_to_unix((body or {}).get("billingCycleEnd"))
    now = time.time()
    window_s = None
    resets_in = None
    if start_s is not None and end_s is not None and end_s > start_s:
        window_s = int(end_s - start_s)
        resets_in = max(0, int(end_s - now))

    auto = _pool(plan_usage.get("autoPercentUsed"), resets_in, window_s)
    api = _pool(plan_usage.get("apiPercentUsed"), resets_in, window_s)
    total = _pool(_total_pct(plan_usage, auto, api), resets_in, window_s)
    # Prefer pace on the hotter pool so the label is useful.
    pace_src = None
    if auto and api:
        pace_src = auto if auto["pct"] >= api["pct"] else api
    else:
        pace_src = api or auto

    return {
        "ok": True,
        "plan": plan,
        "total": total,
        "auto": auto,
        "api": api,
        "pace": _pace(pace_src),
        "cycle_start_s": int(start_s) if start_s is not None else None,
        "cycle_end_s": int(end_s) if end_s is not None else None,
        "resets_in_s": resets_in,
        "spend": _plan_spend(plan_usage),
        "on_demand": _on_demand((body or {}).get("spendLimitUsage")),
        "error": None,
    }


def fetch_quota(force=False):
    """Return Cursor quota dict, using a short in-memory cache. Never raises."""
    now = time.time()
    if _cache["data"] is None:
        disk = cache_util.load_disk("cursor")
        if disk:
            _cache.update(t=0.0, data=disk, err=None)
    if not force and _cache["data"] is not None:
        ttl = CACHE_TTL_S if _cache["data"].get("ok") else FAIL_TTL_S
        if now - _cache["t"] < ttl:
            return _cache["data"]

    empty = {
        "ok": False,
        "plan": None,
        "total": None,
        "auto": None,
        "api": None,
        "pace": None,
        "cycle_start_s": None,
        "cycle_end_s": None,
        "resets_in_s": None,
        "spend": None,
        "on_demand": None,
        "error": None,
    }

    def _keep_stale(err):
        return cache_util.keep_stale(
            _cache, now, err, empty, disk_name="cursor")

    try:
        token = _read_token()
        if not token:
            return _keep_stale(f"no Cursor accessToken in {STATE_DB}")

        plan = _read_plan()
        status, body = _http_usage(token)
        if status != 200:
            return _keep_stale(f"usage HTTP {status}")

        data = parse_usage(body, plan=plan)
        data["stale"] = False
        data["error"] = None
        _cache.update(t=now, data=data, err=None)
        cache_util.save_disk("cursor", data)
        return data
    except Exception as e:
        return _keep_stale(str(e))
