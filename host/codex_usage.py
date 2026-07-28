"""OpenAI Codex plan-usage fetcher (CodexBar-equivalent).

Reads `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`), calls
`GET https://chatgpt.com/backend-api/wham/usage` plus
`GET .../wham/rate-limit-reset-credits`, and returns session/weekly
utilization, pace (deficit/reserve), and limit-reset credit inventory.

Refreshes the OAuth access token only on 401/403 — refresh tokens are
single-use, so we avoid racing Codex CLI / CodexBar.

Stdlib only. Failures degrade to an empty quota dict.
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

import http_util
import cache_util

USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
CREDITS_URL = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
TOKEN_URL = "https://auth.openai.com/oauth/token"
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
UA = "codex-cli"
CACHE_TTL_S = 60
FAIL_TTL_S = 20
# Pace is noisy early in a window (CodexBar hides it under ~3% elapsed).
PACE_MIN_ELAPSED_FRAC = 0.03


def _auth_path():
    home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
    return os.path.join(home, "auth.json")


_cache = {"t": 0.0, "data": None, "err": None}


def _read_auth():
    path = _auth_path()
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def _write_auth(blob):
    path = _auth_path()
    raw = json.dumps(blob, indent=2)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(raw)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def _tokens(blob):
    t = (blob or {}).get("tokens") or {}
    if not t.get("access_token"):
        return None
    return t


def _refresh(blob):
    tokens = _tokens(blob) or {}
    refresh = tokens.get("refresh_token")
    if not refresh:
        raise RuntimeError("no refresh_token in ~/.codex/auth.json")
    data = http_util.request_json(
        TOKEN_URL,
        form_body={
            "client_id": CLIENT_ID,
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "scope": "openid profile email",
        },
        method="POST",
        user_agent=UA,
        timeout=20,
    )
    access = data.get("access_token")
    if not access:
        raise RuntimeError("refresh response missing access_token")
    tokens["access_token"] = access
    if data.get("refresh_token"):
        tokens["refresh_token"] = data["refresh_token"]
    if data.get("id_token"):
        tokens["id_token"] = data["id_token"]
    blob["tokens"] = tokens
    blob["last_refresh"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    _write_auth(blob)
    return tokens


def _http_get(url, access_token, account_id):
    return http_util.request(
        url,
        auth=f"Bearer {access_token}",
        user_agent=UA,
        timeout=20,
        headers={"ChatGPT-Account-Id": account_id} if account_id else None,
    )


def _http_get_authed(url, blob):
    tokens = _tokens(blob)
    if not tokens:
        raise RuntimeError("credentials missing tokens.access_token")
    try:
        return _http_get(url, tokens["access_token"], tokens.get("account_id"))
    except urllib.error.HTTPError as e:
        if e.code not in (401, 403):
            raise
        tokens = _refresh(blob)
        return _http_get(url, tokens["access_token"], tokens.get("account_id"))


def fmt_resets(seconds):
    """Match CodexBar-ish '1h 44m' / '4d 44m'."""
    if seconds is None:
        return None
    s = max(0, int(seconds))
    d, rem = divmod(s, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    if d > 0:
        if h > 0:
            return f"{d}d {h}h"
        if m > 0:
            return f"{d}d {m}m"
        return f"{d}d"
    if h > 0:
        return f"{h}h {m}m" if m else f"{h}h"
    return f"{m}m"


def _prettify_plan(raw):
    if not raw:
        return None
    s = str(raw).strip().lower().replace("_", " ").replace("-", " ")
    # CodexBar naming for multiplier plans.
    aliases = {
        "pro": "Pro 20x",
        "pro lite": "Pro 5x",
        "prolite": "Pro 5x",
        "plus": "Plus",
        "team": "Team",
        "enterprise": "Enterprise",
        "free": "Free",
    }
    if s in aliases:
        return aliases[s]
    return s[:1].upper() + s[1:] if s else None


def _iso_to_unix(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _window_from(obj):
    if not isinstance(obj, dict):
        return None
    pct = obj.get("used_percent")
    if pct is None:
        return None
    window_s = obj.get("limit_window_seconds")
    resets_in = obj.get("reset_after_seconds")
    reset_at = obj.get("reset_at")
    if resets_in is None and isinstance(reset_at, (int, float)):
        # Some payloads use unix seconds; others ms.
        ts = float(reset_at)
        if ts > 1e12:
            ts /= 1000.0
        resets_in = max(0, int(ts - time.time()))
    if isinstance(resets_in, float):
        resets_in = int(resets_in)
    return {
        "pct": round(float(pct), 1),
        "window_s": int(window_s) if isinstance(window_s, (int, float)) else None,
        "resets_in_s": int(resets_in) if isinstance(resets_in, (int, float)) else None,
        "resets_in": fmt_resets(resets_in) if resets_in is not None else None,
    }


def _lane_for(window):
    """Classify a rate-limit window as session (~5h) or week (~7d)."""
    if not window:
        return None
    secs = window.get("window_s") or 0
    if secs >= 3 * 86400:
        return "week"
    return "session"


def _pace(window):
    """Even-consumption pace → deficit/reserve + runs-out ETA (CodexBar)."""
    if not window:
        return None
    pct = window.get("pct")
    window_s = window.get("window_s")
    resets_in = window.get("resets_in_s")
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

    # Time until 100% at current average rate.
    if pct > 0 and elapsed > 0 and pct < 100:
        rate = pct / elapsed  # percent per second
        to_exhaust = (100.0 - pct) / rate
        out["runs_out_in_s"] = max(0, int(to_exhaust))
        out["runs_out_in"] = fmt_resets(out["runs_out_in_s"])
        out["will_last"] = to_exhaust >= resets_in
    elif pct >= 100:
        out["runs_out_in_s"] = 0
        out["runs_out_in"] = "0m"
        out["will_last"] = False
    else:
        out["runs_out_in_s"] = None
        out["runs_out_in"] = None
        out["will_last"] = True
    return out


def _parse_reset_credits(body):
    credits = (body or {}).get("credits") or []
    available = []
    for c in credits:
        if not isinstance(c, dict):
            continue
        if c.get("status") != "available":
            continue
        exp_s = _iso_to_unix(c.get("expires_at"))
        available.append({
            "expires_at": c.get("expires_at"),
            "expires_in_s": max(0, int(exp_s - time.time())) if exp_s else None,
            "expires_in": fmt_resets(max(0, int(exp_s - time.time()))) if exp_s else None,
        })
    available.sort(key=lambda x: x.get("expires_in_s") if x.get("expires_in_s") is not None else 1e18)
    count = body.get("available_count")
    if count is None:
        count = len(available)
    return {
        "available": int(count),
        "expiries": [c["expires_in"] for c in available if c.get("expires_in")],
        "credits": available,
    }


def _parse_spend_control(body):
    """Workspace/individual spend from wham/usage → spend_control."""
    sc = (body or {}).get("spend_control")
    if not isinstance(sc, dict):
        return None
    lim = sc.get("individual_limit")
    if not isinstance(lim, dict):
        return None

    def money(value):
        if value is None or value == "":
            return None
        try:
            return round(float(value), 2)
        except (TypeError, ValueError):
            return None

    used = money(lim.get("used"))
    limit = money(lim.get("limit"))
    remaining = money(lim.get("remaining"))
    if used is None and limit is None and remaining is None:
        return None

    # Some payloads report used/remaining in cents while limit stays in dollars.
    if (
        used is not None and limit is not None and limit > 0
        and used > max(limit * 10, 5000)
        and (used / 100.0) <= limit * 2
    ):
        used = round(used / 100.0, 2)
        if remaining is not None and remaining > limit * 10:
            remaining = round(remaining / 100.0, 2)

    label = None
    if used is not None and limit is not None:
        label = f"${used:,.0f} / ${limit:,.0f}"
    elif used is not None:
        label = f"${used:,.0f} spent"
    elif remaining is not None and limit is not None:
        label = f"${remaining:,.0f} / ${limit:,.0f} left"
    used_pct = lim.get("used_percent")
    try:
        used_pct = float(used_pct) if used_pct is not None else None
    except (TypeError, ValueError):
        used_pct = None

    reached = bool(sc.get("reached"))
    if used is not None and limit is not None and limit > 0:
        # Prefer coherent math over a sticky API flag.
        reached = used >= limit

    return {
        "used_usd": used,
        "limit_usd": limit,
        "remaining_usd": remaining,
        "used_percent": used_pct,
        "reached": reached,
        "source": lim.get("source"),
        "label": label,
    }


def parse_usage(body, credits_body=None):
    """Map wham/usage (+ optional reset-credits) → flat quota dict for /usage."""
    rl = (body or {}).get("rate_limit") or {}
    primary = _window_from(rl.get("primary_window"))
    secondary = _window_from(rl.get("secondary_window"))

    session = week = None
    for w in (primary, secondary):
        lane = _lane_for(w)
        if lane == "session" and session is None:
            session = w
        elif lane == "week" and week is None:
            week = w

    # Team plans often expose only a weekly primary window.
    if week is None and primary and _lane_for(primary) == "week":
        week = primary
    if session is None and primary and _lane_for(primary) == "session":
        session = primary

    # Prefer pace on the weekly lane (matches CodexBar card); fall back to session.
    pace_src = week or session
    pace = _pace(pace_src)

    # Inline summary from usage payload when the dedicated credits call fails.
    reset_credits = None
    inline = (body or {}).get("rate_limit_reset_credits")
    if isinstance(inline, dict) and inline.get("available_count") is not None:
        reset_credits = {
            "available": int(inline["available_count"]),
            "expiries": [],
            "credits": [],
        }
    if credits_body is not None:
        reset_credits = _parse_reset_credits(credits_body)

    return {
        "ok": True,
        "plan": _prettify_plan((body or {}).get("plan_type")),
        "session": session,
        "week": week,
        "pace": pace,
        "reset_credits": reset_credits,
        "credits": (body or {}).get("credits"),
        "spend": _parse_spend_control(body),
    }


def fetch_quota(force=False):
    """Return Codex quota dict, using a short in-memory cache. Never raises."""
    now = time.time()
    if _cache["data"] is None:
        disk = cache_util.load_disk("codex")
        if disk:
            _cache.update(t=0.0, data=disk, err=None)
    if cache_util.fresh(_cache, now, CACHE_TTL_S, FAIL_TTL_S, force):
        return _cache["data"]

    empty = {
        "ok": False, "plan": None, "session": None, "week": None,
        "pace": None, "reset_credits": None, "credits": None,
        "spend": None, "error": None,
    }

    def _keep_stale(err):
        return cache_util.keep_stale(
            _cache, now, err, empty, disk_name="codex")

    try:
        blob = _read_auth()
        if not blob:
            return _keep_stale(f"no Codex credentials at {_auth_path()}")
        if not _tokens(blob):
            return _keep_stale("auth.json missing tokens.access_token")

        status, body = _http_get_authed(USAGE_URL, blob)
        if status != 200:
            return _keep_stale(f"usage HTTP {status}")

        credits_body = None
        try:
            cstatus, credits_body = _http_get_authed(CREDITS_URL, blob)
            if cstatus != 200:
                credits_body = None
        except Exception:
            credits_body = None

        data = parse_usage(body, credits_body)
        data["stale"] = False
        data["error"] = None
        return cache_util.store(_cache, now, data, disk_name="codex")
    except Exception as e:
        return _keep_stale(str(e))
