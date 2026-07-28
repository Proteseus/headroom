"""Shared helpers for coding-quota fetchers (pool dicts + resets)."""

from __future__ import annotations

from datetime import datetime, timezone

import oauth_usage


def pool(pct, resets_in_s=None, window_s=None):
    """Normalize a quota window the way Claude/Codex/Cursor payloads do."""
    if pct is None:
        return None
    try:
        value = round(float(pct), 1)
    except (TypeError, ValueError):
        return None
    return {
        "pct": value,
        "resets_in_s": int(resets_in_s) if resets_in_s is not None else None,
        "resets_in": oauth_usage.fmt_resets(resets_in_s),
        "window_s": int(window_s) if window_s else None,
    }


def resets_from_unix(ts, now=None):
    """Seconds until unix timestamp `ts` (ms or s). None if past/unknown."""
    if ts is None:
        return None
    try:
        when = float(ts)
    except (TypeError, ValueError):
        return None
    if when > 1e12:
        when /= 1000.0
    now = now if now is not None else time_now()
    remaining = int(when - now)
    return remaining if remaining > 0 else 0


def resets_from_iso(value, now=None):
    if not value:
        return None
    text = str(value).strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        when = datetime.fromisoformat(text)
    except ValueError:
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    now = now if now is not None else time_now()
    remaining = int(when.timestamp() - now)
    return remaining if remaining > 0 else 0


def time_now():
    return datetime.now(timezone.utc).timestamp()


def used_pct(used, limit):
    try:
        used_f = float(used)
        limit_f = float(limit)
    except (TypeError, ValueError):
        return None
    if limit_f <= 0:
        return None
    return max(0.0, min(100.0, 100.0 * used_f / limit_f))


def remaining_pct_to_used(remaining_pct):
    try:
        left = float(remaining_pct)
    except (TypeError, ValueError):
        return None
    return max(0.0, min(100.0, 100.0 - left))
