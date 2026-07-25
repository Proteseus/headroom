"""The source registry: one entry per thing Headroom watches.

This is the single place that knows a source exists. Adding one means adding a
row to SOURCES — the HTTP payload, the Mac Settings list, the ESP32 footer, the
poll schedule, and the log line all follow from it. Enabled flags persist to
~/.headroom/sources.json; both Mac Settings and the ESP32 read them back via
/usage → sources[].

Stdlib only.
"""

from __future__ import annotations

import json
import os
import threading
from typing import Callable, NamedTuple

import codex_usage
import cursor_usage
import git_activity
import github_actions
import local_servers
import oauth_usage
import supabase_usage
import vercel_builds

STORE_PATH = os.path.expanduser("~/.headroom/sources.json")


class Source(NamedTuple):
    """Everything the host needs to know about one watched service."""

    id: str
    title: str
    hint: str
    poll_s: int          # how often the background poller refreshes it
    fetch: Callable      # fetch(force=bool) -> payload dict, never raises
    detail: Callable     # detail(payload) -> short status string or None
    summary: Callable    # summary(payload) -> log line body for a good fetch
    blank: Callable      # blank() -> the payload shape before the first fetch


# ---------------- detail formatters (Mac Settings + ESP32 rows) ----------------

def _window_detail(payload, key, label):
    plan = payload.get("plan")
    pct = (payload.get(key) or {}).get("pct")
    if plan and pct is not None:
        return f"{plan} · {label} {pct:.0f}%"
    return plan or payload.get("error")


def _detail_claude(payload):
    return _window_detail(payload, "week", "week")


def _detail_codex(payload):
    return _window_detail(payload, "week", "week")


def _detail_cursor(payload):
    return _window_detail(payload, "total", "total")


def _detail_vercel(payload):
    team = payload.get("team")
    count = len(payload.get("deployments") or [])
    if team:
        return f"{team} · {count} deploys"
    return payload.get("error")


def _detail_git(payload):
    if not payload.get("ok"):
        return payload.get("error")
    return f"{len(payload.get('commits') or [])} commits"


def _detail_github(payload):
    if not payload.get("configured"):
        return payload.get("error") or "not connected"
    fails = payload.get("fail_count") or 0
    running = payload.get("running_count") or 0
    bits = []
    if fails:
        bits.append(f"{fails} failed")
    if running:
        bits.append(f"{running} running")
    return " · ".join(bits) if bits else "all clear"


def _detail_local(payload):
    if not payload.get("ok"):
        return payload.get("error")
    count = len(payload.get("servers") or [])
    return f"{payload.get('host') or 'local'} · {count} servers"


def _detail_supabase(payload):
    if not payload.get("configured"):
        return payload.get("error") or "not connected"
    alerts = payload.get("alert_count") or 0
    count = payload.get("project_count") or 0
    if alerts:
        return f"{count} projects · {alerts} alerts"
    return f"{count} projects"


# ---------------- log summaries (stdout under the LaunchAgent) ----------------

def _summary_claude(payload):
    session = (payload.get("session") or {}).get("pct")
    week = (payload.get("week") or {}).get("pct")
    return f"plan={payload.get('plan')}  session={session}%  week={week}%"


def _summary_codex(payload):
    session = (payload.get("session") or {}).get("pct")
    week = (payload.get("week") or {}).get("pct")
    pace = (payload.get("pace") or {}).get("label") or "-"
    credits = (payload.get("reset_credits") or {}).get("available")
    return (f"plan={payload.get('plan')}  session={session}%  week={week}%  "
            f"pace={pace}  credits={credits}")


def _summary_cursor(payload):
    auto = (payload.get("auto") or {}).get("pct")
    api = (payload.get("api") or {}).get("pct")
    return (f"plan={payload.get('plan')}  auto={auto}%  api={api}%  "
            f"resets={payload.get('resets_in_s')}")


def _summary_vercel(payload):
    return (f"team={payload.get('team')}  "
            f"deploys={len(payload.get('deployments') or [])}")


def _summary_git(payload):
    return f"commits={len(payload.get('commits') or [])}"


def _summary_github(payload):
    return (f"fails={payload.get('fail_count')}  "
            f"running={payload.get('running_count')}  "
            f"repos={len(payload.get('repos') or [])}")


def _summary_local(payload):
    return (f"host={payload.get('host')}  "
            f"servers={len(payload.get('servers') or [])}")


def _summary_supabase(payload):
    return (f"projects={payload.get('project_count')} "
            f"alerts={payload.get('alert_count')}")


# ---------------- blank payloads (shape before the first fetch) ----------------

def _blank_quota():
    return {"ok": False, "plan": None, "session": None, "week": None}


def _blank_cursor():
    return {"ok": False, "plan": None, "auto": None, "api": None}


def _blank_vercel():
    return {"ok": False, "team": None, "deployments": []}


def _blank_git():
    return {"ok": False, "commits": []}


def _blank_github():
    return {"ok": False, "configured": False, "runs": [],
            "fail_count": 0, "running_count": 0, "error": None}


def _blank_local():
    return {"ok": False, "host": None, "servers": []}


def _blank_supabase():
    return {"ok": False, "configured": False, "projects": [],
            "project_count": 0, "healthy_count": 0, "alert_count": 0}


# Order matters — Mac Settings rows and the ESP32 footer dots follow it.
SOURCES = (
    Source("claude", "Claude", "Keychain / ~/.claude credentials", 60,
           oauth_usage.fetch_quota, _detail_claude, _summary_claude,
           _blank_quota),
    Source("codex", "Codex", "~/.codex/auth.json", 60,
           codex_usage.fetch_quota, _detail_codex, _summary_codex,
           _blank_quota),
    Source("cursor", "Cursor", "Cursor IDE signed-in JWT", 60,
           cursor_usage.fetch_quota, _detail_cursor, _summary_cursor,
           _blank_cursor),
    Source("vercel", "Vercel", "Vercel CLI login", 60,
           vercel_builds.fetch_deployments, _detail_vercel, _summary_vercel,
           _blank_vercel),
    Source("git", "Git", "Local commits under configured Dev root", 60,
           git_activity.fetch_commits, _detail_git, _summary_git,
           _blank_git),
    Source("github", "GitHub Actions", "Failed / running workflows", 90,
           github_actions.fetch_actions, _detail_github, _summary_github,
           _blank_github),
    Source("local", "Local", "Listening dev servers", local_servers.CACHE_TTL_S,
           local_servers.fetch_servers, _detail_local, _summary_local,
           _blank_local),
    Source("supabase", "Supabase", "PAT in Headroom Keychain", 5 * 60,
           supabase_usage.fetch_projects, _detail_supabase, _summary_supabase,
           _blank_supabase),
)

BY_ID = {source.id: source for source in SOURCES}
SOURCE_IDS = tuple(source.id for source in SOURCES)

# Refreshing any of these should also feed the daily burn history.
BURN_SOURCE_IDS = ("claude", "codex", "cursor")


def get(source_id):
    return BY_ID.get(source_id)


def meta_for(source_id):
    source = BY_ID.get(source_id)
    if source is None:
        return {"title": source_id, "hint": ""}
    return {"title": source.title, "hint": source.hint}


def detail_for(source_id, payload):
    """Short status line for Mac Settings. Never raises."""
    source = BY_ID.get(source_id)
    payload = payload or {}
    if source is None:
        return payload.get("error")
    try:
        return source.detail(payload)
    except Exception:
        return payload.get("error")


def blank_state():
    """Fresh payload dict for every source, keyed by id."""
    return {source.id: source.blank() for source in SOURCES}


# ---------------- enabled flags (~/.headroom/sources.json) ----------------

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
            if sid in BY_ID:
                enabled[sid] = bool(value)
        state["enabled"] = enabled
        _save(state)
        return dict(enabled)


def reset_for_tests():
    """Drop cached enabled flags (unit tests only)."""
    global _state
    with _lock:
        _state = None
