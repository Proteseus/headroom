"""Shared in-memory cache helpers for Headroom fetchers."""

from __future__ import annotations


def keep_stale(cache, now, err, empty):
    """Prefer last-good snapshot on transient failure instead of wiping UI.

    `cache` is a dict with at least `data` (and usually `t`). On success paths
    callers still overwrite cache themselves.
    """
    prev = cache.get("data")
    if prev and prev.get("ok"):
        stale = dict(prev)
        stale["stale"] = True
        stale["error"] = err
        cache.update(t=now, data=stale, err=err)
        return stale
    out = dict(empty)
    out["ok"] = False
    out["error"] = err
    out["stale"] = False
    cache.update(t=now, data=out, err=err)
    return out
