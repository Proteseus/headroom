"""Shared in-memory + last-good disk cache helpers for Headroom fetchers."""

from __future__ import annotations

import json
import os
import tempfile

CACHE_DIR = os.path.expanduser("~/.headroom/cache")


def _disk_path(name: str) -> str:
    return os.path.join(CACHE_DIR, f"{name}.json")


def load_disk(name: str):
    """Return last-good snapshot from disk, or None."""
    try:
        with open(_disk_path(name)) as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError, TypeError):
        return None
    return data if isinstance(data, dict) and data.get("ok") else None


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


def keep_stale(cache, now, err, empty, disk_name=None):
    """Prefer last-good snapshot on transient failure instead of wiping UI.

    `cache` is a dict with at least `data` (and usually `t`). On success paths
    callers still overwrite cache themselves. When `disk_name` is set, falls
    back to ~/.headroom/cache/<name>.json if memory is empty.
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
