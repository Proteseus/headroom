"""OpenCode Quota integration.

Uses the optional ``opencode-quota show --json`` helper when installed. The
helper owns OpenCode Go authentication/dashboard scraping; Headroom only reads
its structured stdout and never handles the auth cookie itself.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import time

CACHE_TTL_S = 300
FAIL_TTL_S = 30
_EMPTY = {"ok": False, "configured": False, "plan": None, "error": None}
_cache = {"t": 0.0, "data": None}


def _binary():
    return shutil.which("opencode-quota")


def signed_in():
    return _binary() is not None or bool(
        os.environ.get("OPENCODE_GO_WORKSPACE_ID")
        and os.environ.get("OPENCODE_GO_AUTH_COOKIE")
    )


def _entry_percent(entry):
    remaining = entry.get("percentRemaining")
    if remaining is None:
        return None
    try:
        return max(0.0, min(100.0, 100.0 - float(remaining)))
    except (TypeError, ValueError):
        return None


def _fetch_command():
    binary = _binary()
    if not binary:
        return None
    return [binary, "show", "--json", "--provider", "opencode-go"]


def fetch_quota(force=False):
    now = time.time()
    if not signed_in():
        result = {**_EMPTY, "error": "Install/configure opencode-quota"}
        _cache.update(t=now, data=result)
        return result
    if not force and _cache["data"] and now - _cache["t"] < CACHE_TTL_S:
        return _cache["data"]
    command = _fetch_command()
    try:
        if not command:
            raise RuntimeError("opencode-quota command not found")
        completed = subprocess.run(
            command, check=True, capture_output=True, text=True, timeout=30,
            env=os.environ.copy(),
        )
        body = json.loads(completed.stdout)
        entries = body.get("entries") if isinstance(body, dict) else None
        entries = entries if isinstance(entries, list) else []
        pools = {}
        for entry in entries:
            if not isinstance(entry, dict) or entry.get("resultType") != "quota":
                continue
            pct = _entry_percent(entry)
            if pct is None:
                continue
            label = str(entry.get("name") or entry.get("label") or "quota").lower()
            key = "5h" if "5h" in label or "5 hour" in label else (
                "weekly" if "week" in label else "monthly" if "month" in label else "5h"
            )
            pools[key] = {"pct": pct, "pace_pct": None}
        if not pools:
            raise ValueError("OpenCode quota response contained no active quota windows")
        result = {
            "ok": True, "configured": True, "plan": "OpenCode Go",
            "error": None, "updated_at": int(now), "stale": False,
            **pools,
        }
    except (OSError, subprocess.SubprocessError, ValueError, json.JSONDecodeError) as exc:
        result = {**_EMPTY, "error": str(exc), "updated_at": int(now), "stale": False}
    _cache.update(t=now, data=result)
    return result
