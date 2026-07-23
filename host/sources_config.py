"""Enabled-source config for Headroom host + ESP32.

Persists to ~/.headroom/sources.json. Both the Mac Settings panel and the
ESP32 read the same enabled flags via /usage → sources[].
"""

from __future__ import annotations

import json
import os
import threading

STORE_PATH = os.path.expanduser("~/.headroom/sources.json")

# Order matters — Mac Settings and ESP32 footer follow this.
SOURCE_IDS = (
    "claude",
    "codex",
    "cursor",
    "vercel",
    "git",
    "github",
    "local",
    "supabase",
)

SOURCE_META = {
    "claude": {"title": "Claude", "hint": "Keychain / ~/.claude credentials"},
    "codex": {"title": "Codex", "hint": "~/.codex/auth.json"},
    "cursor": {"title": "Cursor", "hint": "Cursor IDE signed-in JWT"},
    "vercel": {"title": "Vercel", "hint": "Vercel CLI login (ev-io)"},
    "git": {"title": "Git", "hint": "Local ~/Dev commits"},
    "github": {"title": "GitHub Actions", "hint": "Failed / running workflows"},
    "local": {"title": "Local", "hint": "Listening dev servers"},
    "supabase": {"title": "Supabase", "hint": "PAT in Headroom Keychain"},
}

_lock = threading.Lock()
_state = None


def _default_enabled():
    return {sid: True for sid in SOURCE_IDS}


def _load():
    try:
        with open(STORE_PATH) as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {"enabled": _default_enabled()}
    if not isinstance(data, dict):
        return {"enabled": _default_enabled()}
    enabled = _default_enabled()
    raw = data.get("enabled") if isinstance(data.get("enabled"), dict) else {}
    for sid in SOURCE_IDS:
        if sid in raw:
            enabled[sid] = bool(raw[sid])
    return {"enabled": enabled}


def _save(state):
    folder = os.path.dirname(STORE_PATH)
    os.makedirs(folder, exist_ok=True)
    raw = json.dumps(state, indent=2, sort_keys=True)
    tmp = STORE_PATH + ".tmp"
    with open(tmp, "w") as handle:
        handle.write(raw)
    os.replace(tmp, STORE_PATH)


def _state_locked():
    global _state
    if _state is None:
        _state = _load()
    return _state


def enabled_map():
    with _lock:
        return dict(_state_locked()["enabled"])


def is_enabled(source_id):
    return bool(enabled_map().get(source_id, True))


def set_enabled(updates):
    """Apply {source_id: bool} updates. Returns the full enabled map."""
    with _lock:
        state = _state_locked()
        enabled = dict(state["enabled"])
        for sid, value in (updates or {}).items():
            if sid in SOURCE_IDS:
                enabled[sid] = bool(value)
        state["enabled"] = enabled
        _save(state)
        return dict(enabled)


def meta_for(source_id):
    return SOURCE_META.get(source_id, {"title": source_id, "hint": ""})
