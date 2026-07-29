"""Shared in-memory + last-good disk cache helpers for Headroom fetchers."""

from __future__ import annotations

import json
import os
import tempfile
import time

CACHE_DIR = os.path.expanduser("~/.headroom/cache")


def _disk_path(name: str) -> str:
    return os.path.join(CACHE_DIR, f"{name}.json")


def load_disk(name: str):
    """Return last-good snapshot from disk, or None.

    A snapshot written before `fetched_at` existed gets one from the file's
    mtime, which is the same instant by construction — `save_disk` only ever
    runs on a good fetch. Without it the first snapshot after an upgrade is the
    one case that cannot be aged, and that case is exactly a host restarting
    onto a cache it has been unable to refresh.
    """
    path = _disk_path(name)
    try:
        with open(path) as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError, TypeError):
        return None
    if not (isinstance(data, dict) and data.get("ok")):
        return None
    if not isinstance(data.get("fetched_at"), (int, float)):
        try:
            data["fetched_at"] = os.path.getmtime(path)
        except OSError:
            pass
    return data


def save_disk(name: str, data: dict) -> None:
    """Persist a good snapshot so timeouts can reuse it after restarts."""
    if not isinstance(data, dict) or not data.get("ok"):
        return
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        path = _disk_path(name)
        fd, tmp = tempfile.mkstemp(dir=CACHE_DIR, suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as handle:
                json.dump(data, handle, separators=(",", ":"))
            os.replace(tmp, path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
    except OSError:
        pass


def fresh(cache, now, ttl_s, fail_ttl_s, force=False):
    """True when the in-memory copy is young enough to serve as-is.

    A cache holding an error retries on the shorter `fail_ttl_s`, so a 429 or
    a dropped VPN clears in seconds rather than making the meter sit wrong for
    a full TTL.
    """
    if force or cache.get("data") is None:
        return False
    return now - cache.get("t", 0.0) < (
        fail_ttl_s if cache.get("err") else ttl_s
    )


def store(cache, now, data, disk_name=None):
    """Record a good fetch in memory and, when named, as the last-good disk
    snapshot `keep_stale` falls back to. Returns `data` so callers can
    `return cache_util.store(...)`."""
    data["fetched_at"] = now
    if disk_name:
        save_disk(disk_name, data)
    cache.update(t=now, data=data, err=None)
    return data


def keep_stale(cache, now, err, empty, disk_name=None):
    """Prefer last-good snapshot on transient failure instead of wiping UI.

    `cache` is a dict with at least `data` (and usually `t`). On success paths
    callers still overwrite cache themselves. When `disk_name` is set, falls
    back to ~/.headroom/cache/<name>.json if memory is empty.

    `fetched_at` rides along from the snapshot untouched. `cache["t"]` is when
    we last *tried*, which is what the retry TTL needs; the payload has to
    carry when the numbers were last *true*, or a source that has been failing
    for a day reads as one poll old and nothing downstream can tell the
    difference.
    """
    prev = cache.get("data")
    if not (prev and prev.get("ok")) and disk_name:
        prev = load_disk(disk_name)
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


# How long a last-good snapshot may still stand in for a live reading. A poll
# that misses once is a blip — the numbers are seconds old and everything
# derived from them holds. Past this the percentages are still worth showing,
# because they are the last thing that was true, but nothing computed against
# *now* may be: a countdown, a pace, a forecast, or a fresh chart sample all
# claim a currency the reading no longer has.
TRUSTED_STALE_S = 600


def age_s(payload, now=None):
    """Seconds since these numbers were true, or None if the source never said."""
    if not isinstance(payload, dict):
        return None
    fetched = payload.get("fetched_at")
    if not isinstance(fetched, (int, float)) or fetched <= 0:
        return None
    return max(0.0, (time.time() if now is None else float(now)) - fetched)


def trusted(payload, now=None):
    """True when a payload is fresh enough to derive live values from.

    A payload with no `fetched_at` predates the field, so it is taken at face
    value rather than being treated as ancient — an old snapshot on disk must
    not make a working source look broken on the first poll after an upgrade.
    """
    if not isinstance(payload, dict) or not payload.get("ok"):
        return False
    if not payload.get("stale"):
        return True
    age = age_s(payload, now)
    return age is None or age <= TRUSTED_STALE_S
