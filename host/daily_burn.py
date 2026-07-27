"""Daily quota-burn history across enabled coding providers.

On each quota refresh, records positive %-point deltas for each provider's
headline meter (derived from sources_config — e.g. Claude/Codex weekly,
Cursor total). Window resets (pct drop) update the baseline without counting
negative burn.

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

import sources_config

STORE_PATH = os.path.expanduser("~/.headroom/daily_burn.json")
HISTORY_DAYS = 30
EXPOSE_DAYS = 14
# Treat a drop of this many points as a window reset, not reverse burn.
RESET_DROP_PCT = 2.0

_lock = threading.Lock()
_state = None  # lazy-loaded dict


def _providers():
    return sources_config.BURN_SOURCE_IDS


def _today_key(tz):
    return datetime.now(tz).date().isoformat()


def _blank_day():
    return {p: 0.0 for p in _providers()}


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


def observe(quota=None, codex=None, cursor=None, *, payloads=None,
            tz=None, now=None, persist=True):
    """Record burn from the latest quota snapshots. Returns today's totals.

    Prefer `payloads={provider_id: nested_quota}`. The positional
    quota/codex/cursor args remain for older call sites and tests.
    """
    global _state
    if payloads is None:
        payloads = {
            "claude": quota or {},
            "codex": codex or {},
            "cursor": cursor or {},
        }
    tz = tz or ZoneInfo("Europe/Berlin")
    day = _today_key(tz)
    now = time.time() if now is None else float(now)
    providers = _providers()

    with _lock:
        if _state is None:
            _state = _load()
        state = _state
        days = dict(state.get("days") or {})
        last = dict(state.get("last") or {})
        day_row = dict(days.get(day) or _blank_day())

        for provider in providers:
            pct = sources_config.headline_pct(
                provider, payloads.get(provider) or {})
            prev = (last.get(provider) or {}).get("pct")
            burn = _delta(prev, pct)
            if burn is None:
                continue
            day_row[provider] = round(float(day_row.get(provider) or 0) + burn, 2)
            last[provider] = {"pct": pct, "t": now}

        for provider in providers:
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
    """Return oldest→newest day rows for the chart, filling missing days with 0.

    Legacy claude/codex/cursor keys stay for firmware + older Mac builds.
    `burns` is the same map, ready for a fully dynamic client.
    """
    global _state
    tz = tz or ZoneInfo("Europe/Berlin")
    providers = _providers()
    with _lock:
        if _state is None:
            _state = _load()
        stored = dict((_state or {}).get("days") or {})

    today = datetime.now(tz).date()
    out = []
    for i in range(days - 1, -1, -1):
        d = today - timedelta(days=i)
        key = d.isoformat()
        row = stored.get(key) or {}
        burns = {
            provider: round(float(row.get(provider) or 0), 2)
            for provider in providers
        }
        entry = {
            "date": key,
            "burns": burns,
            "total": round(sum(burns.values()), 2),
        }
        # Dual-write fixed columns so existing Mac / ESP32 parsers keep working.
        for provider in providers:
            entry[provider] = burns[provider]
        out.append(entry)
    return out


def reset_for_tests():
    """Clear in-memory state (unit tests only)."""
    global _state
    with _lock:
        _state = None
