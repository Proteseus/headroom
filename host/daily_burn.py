"""Daily quota-burn history across Claude / Codex / Cursor.

On each quota refresh, records positive %-point deltas for each provider's
headline meter (Claude/Codex weekly, Cursor total). Window resets (pct drop)
update the baseline without counting negative burn.

Persists to ~/.headroom/daily_burn.json so history survives host restarts.
Stdlib only.
"""

from __future__ import annotations

import json
import os
import threading
import time
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

STORE_PATH = os.path.expanduser("~/.headroom/daily_burn.json")
HISTORY_DAYS = 30
EXPOSE_DAYS = 14
# Treat a drop of this many points as a window reset, not reverse burn.
RESET_DROP_PCT = 2.0
PROVIDERS = ("claude", "codex", "cursor")

_lock = threading.Lock()
_state = None  # lazy-loaded dict


def _today_key(tz):
    return datetime.now(tz).date().isoformat()


def _blank_day():
    return {p: 0.0 for p in PROVIDERS}


def _default_state():
    return {"last": {}, "days": {}}


def _load():
    try:
        with open(STORE_PATH) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return _default_state()
    if not isinstance(data, dict):
        return _default_state()
    last = data.get("last") if isinstance(data.get("last"), dict) else {}
    days = data.get("days") if isinstance(data.get("days"), dict) else {}
    return {"last": last, "days": days}


def _save(state):
    folder = os.path.dirname(STORE_PATH)
    os.makedirs(folder, exist_ok=True)
    raw = json.dumps(state, indent=2, sort_keys=True)
    tmp = STORE_PATH + ".tmp"
    with open(tmp, "w") as f:
        f.write(raw)
    os.replace(tmp, STORE_PATH)


def _prune(days, tz, keep=HISTORY_DAYS):
    cutoff = (datetime.now(tz).date() - timedelta(days=keep - 1)).isoformat()
    return {k: v for k, v in days.items() if isinstance(k, str) and k >= cutoff}


def _headline_pct(provider, quota, codex, cursor):
    """Pick the stable plan window used for burn accounting."""
    if provider == "claude":
        week = (quota.get("week") or {}).get("pct")
        session = (quota.get("session") or {}).get("pct")
        if week is not None:
            return float(week)
        if session is not None:
            return float(session)
        return None
    if provider == "codex":
        week = (codex.get("week") or {}).get("pct")
        session = (codex.get("session") or {}).get("pct")
        if week is not None:
            return float(week)
        if session is not None:
            return float(session)
        return None
    # cursor
    total = (cursor.get("total") or {}).get("pct")
    if total is not None:
        return float(total)
    auto = (cursor.get("auto") or {}).get("pct")
    api = (cursor.get("api") or {}).get("pct")
    vals = [v for v in (auto, api) if v is not None]
    return float(max(vals)) if vals else None


def _delta(prev, current):
    """Return burn to add, or None if this sample only updates the baseline."""
    if current is None:
        return None
    if prev is None:
        return 0.0
    try:
        prev_f = float(prev)
        cur_f = float(current)
    except (TypeError, ValueError):
        return None
    if cur_f + RESET_DROP_PCT < prev_f:
        # Window reset — re-baseline, no burn this tick.
        return 0.0
    burn = cur_f - prev_f
    return burn if burn > 0 else 0.0


def observe(quota, codex, cursor, *, tz=None, now=None, persist=True):
    """Record burn from the latest quota snapshots. Returns today's totals."""
    global _state
    tz = tz or ZoneInfo("Europe/Berlin")
    day = _today_key(tz)
    now = time.time() if now is None else float(now)

    with _lock:
        if _state is None:
            _state = _load()
        state = _state
        days = dict(state.get("days") or {})
        last = dict(state.get("last") or {})
        day_row = dict(days.get(day) or _blank_day())

        for provider in PROVIDERS:
            pct = _headline_pct(provider, quota or {}, codex or {}, cursor or {})
            prev = (last.get(provider) or {}).get("pct")
            burn = _delta(prev, pct)
            if burn is None:
                continue
            day_row[provider] = round(float(day_row.get(provider) or 0) + burn, 2)
            last[provider] = {"pct": pct, "t": now}

        for provider in PROVIDERS:
            day_row[provider] = round(float(day_row.get(provider) or 0), 2)

        days[day] = day_row
        days = _prune(days, tz)
        state = {"last": last, "days": days}
        _state = state
        if persist:
            try:
                _save(state)
            except OSError as exc:
                print("daily_burn save error:", exc)
        return dict(day_row)


def series(*, tz=None, days=EXPOSE_DAYS):
    """Return oldest→newest day rows for the chart, filling missing days with 0."""
    global _state
    tz = tz or ZoneInfo("Europe/Berlin")
    with _lock:
        if _state is None:
            _state = _load()
        stored = dict((_state or {}).get("days") or {})

    today = datetime.now(tz).date()
    out = []
    for i in range(days - 1, -1, -1):
        d = today - timedelta(days=i)
        key = d.isoformat()
        row = stored.get(key) or _blank_day()
        claude = round(float(row.get("claude") or 0), 2)
        codex = round(float(row.get("codex") or 0), 2)
        cursor = round(float(row.get("cursor") or 0), 2)
        out.append({
            "date": key,
            "claude": claude,
            "codex": codex,
            "cursor": cursor,
            "total": round(claude + codex + cursor, 2),
        })
    return out


def reset_for_tests():
    """Clear in-memory state (unit tests only)."""
    global _state
    with _lock:
        _state = None
