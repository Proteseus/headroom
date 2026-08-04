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
_HOST_DIR = os.path.dirname(os.path.abspath(__file__))
_BRIDGE = os.path.join(_HOST_DIR, "opencode_go_bridge.mjs")
_BUNDLED_CLI = os.path.join(
    os.path.dirname(_HOST_DIR), "tools", "node_modules", ".bin",
    "opencode-quota")
_WINDOW_SECONDS = {"5h": 5 * 3600, "weekly": 7 * 86400,
                   "monthly": 30 * 86400}
_EMPTY = {"ok": False, "configured": False, "plan": None, "error": None}
_cache = {"t": 0.0, "data": None}


def _binary():
    return shutil.which("opencode-quota") or (
        _BUNDLED_CLI if os.access(_BUNDLED_CLI, os.X_OK) else None)


def _bridge_command():
    node = shutil.which("node")
    if node and os.path.isfile(_BRIDGE) and os.path.isfile(
            os.path.join(os.path.dirname(_HOST_DIR), "tools", "node_modules",
                         "@slkiser", "opencode-quota", "dist", "lib",
                         "opencode-go.js")):
        return [node, _BRIDGE]
    return None


def _has_config():
    if (os.environ.get("OPENCODE_GO_WORKSPACE_ID")
            and os.environ.get("OPENCODE_GO_AUTH_COOKIE")):
        return True
    config_home = os.environ.get("XDG_CONFIG_HOME")
    if not config_home:
        config_home = os.path.join(os.path.expanduser("~"), ".config")
    path = os.path.join(config_home, "opencode", "opencode-quota",
                        "opencode-go.json")
    try:
        with open(path, encoding="utf-8") as handle:
            body = json.load(handle)
        return bool(body.get("workspaceId") and body.get("authCookie"))
    except (OSError, ValueError, AttributeError):
        return False


def signed_in():
    return _has_config() and (
        _bridge_command() is not None or _binary() is not None)


def _entry_percent(entry):
    remaining = entry.get("percentRemaining")
    if remaining is None:
        return None
    try:
        return max(0.0, min(100.0, 100.0 - float(remaining)))
    except (TypeError, ValueError):
        return None


def _fetch_command():
    bridge = _bridge_command()
    if bridge:
        return bridge
    binary = _binary()
    if not binary:
        return None
    return [binary, "show", "--json", "--provider", "opencode-go"]


def _entries(body):
    """Accept both the old quota-v1 envelope and current CLI export v2."""
    entries = body.get("entries") if isinstance(body, dict) else None
    if isinstance(entries, list):
        return entries
    providers = body.get("providers") if isinstance(body, dict) else None
    provider = providers.get("opencode-go") if isinstance(providers, dict) else None
    entries = provider.get("entries") if isinstance(provider, dict) else None
    return entries if isinstance(entries, list) else []


def _reset_seconds(entry, now):
    value = entry.get("resetInSec")
    if value is None and isinstance(entry.get("resetAt"), (int, float)):
        value = entry["resetAt"] - now
    try:
        return max(0, int(float(value)))
    except (TypeError, ValueError):
        return None


def _pace_percent(resets_in_s, window_s):
    if resets_in_s is None or not window_s:
        return None
    elapsed = max(0, min(window_s, window_s - resets_in_s))
    return round(100.0 * elapsed / window_s, 1)


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
        child_env = os.environ.copy()
        # Node's fetch does not honor HTTPS_PROXY by default. This host is
        # commonly run behind the same environment proxy curl/Python use.
        child_env.setdefault("NODE_USE_ENV_PROXY", "1")
        completed = subprocess.run(
            command, check=True, capture_output=True, text=True, timeout=30,
            env=child_env,
        )
        body = json.loads(completed.stdout)
        entries = _entries(body)
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
            window_s = _WINDOW_SECONDS[key]
            resets_in_s = _reset_seconds(entry, now)
            pools[key] = {
                "pct": pct,
                "pace_pct": _pace_percent(resets_in_s, window_s),
                "resets_in_s": resets_in_s,
                "window_s": window_s,
            }
        if not pools:
            message = body.get("error") if isinstance(body, dict) else None
            raise ValueError(message or
                             "OpenCode quota response contained no active quota windows")
        result = {
            "ok": True, "configured": True, "plan": "OpenCode Go",
            "error": None, "updated_at": int(now), "stale": False,
            **pools,
        }
    except (OSError, subprocess.SubprocessError, ValueError, json.JSONDecodeError) as exc:
        # The collector and credentials exist; distinguish a quota/dashboard
        # failure from a disconnected source in setup and widget clients.
        result = {
            **_EMPTY, "configured": True, "plan": "OpenCode Go",
            "error": str(exc), "updated_at": int(now), "stale": False,
        }
    _cache.update(t=now, data=result)
    return result
