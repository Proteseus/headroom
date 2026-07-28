"""The source registry: one entry per thing Headroom watches.

This is the single place that knows a source exists. Adding one means adding a
row to SOURCES — the HTTP payload, the Mac Settings list, the ESP32 footer, the
poll schedule, and the log line all follow from it. Enabled flags persist to
~/.headroom/sources.json; both Mac Settings and the ESP32 read them back via
/usage → sources[].

Quota providers (Claude / Codex / Cursor / …) are sources with kind="quota"
plus pool specs. POOLS, daily-burn headlines, and /usage → providers[] all
derive from those rows — so a Claude-only user can disable the rest, and a
new provider is one registry entry + a fetcher rather than a client enum.

`kind` is about metering; `group` is about what the thing *is*. Onboarding and
Settings split rows by group: the AI coding tools you're signed into locally
(no keys to paste) versus the dev tools you connect with a token. Section
titles live in Shared/HeadroomCopy.swift — the registry only owns membership.

Stdlib only.
"""

from __future__ import annotations

import json
import os
import threading
from typing import Callable, NamedTuple, Optional

import codex_usage
import copilot_usage
import cursor_usage
import detect_sources
import gemini_usage
import git_activity
import github_actions
import jetbrains_usage
import local_servers
import oauth_usage
import plausible_usage
import supabase_usage
import vercel_builds
import windsurf_usage
import zed_usage

STORE_PATH = os.path.expanduser("~/.headroom/sources.json")

# Onboarding / Settings groups. Order is the order sections render in.
GROUP_AI = "ai"              # coding models you're already signed into
GROUP_DEVTOOLS = "devtools"  # everything else you point Headroom at
GROUP_IDS = (GROUP_AI, GROUP_DEVTOOLS)


class PoolSpec(NamedTuple):
    """One quota meter on a provider payload (session, week, total, …)."""

    id: str
    key: str
    title: str
    default_window_s: Optional[int] = None
    # Sampled for burndown history even when False; False hides the ring.
    ring: bool = True


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
    # "quota" feeds burndown / daily burn / provider tabs; everything else is
    # activity (Vercel, git, …) and only shows in Settings + ship-status panes.
    kind: str = "activity"
    # GROUP_AI or GROUP_DEVTOOLS — which Settings/onboarding section it lands
    # in. Independent of kind: a dev tool could grow a quota meter one day.
    group: str = GROUP_DEVTOOLS
    pools: tuple = ()
    # Daily-burn headline: try these pool keys in order (first pct wins).
    headline: tuple = ()
    # If every headline key is missing, use max(pct) across these (Cursor).
    headline_fallback_max: tuple = ()
    # #RRGGBB — shared with firmware COL_* and macos UsageProvider.tint.
    accent: Optional[str] = None


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


def _detail_copilot(payload):
    return _window_detail(payload, "premium", "premium")


def _detail_gemini(payload):
    return _window_detail(payload, "pro", "pro")


def _detail_windsurf(payload):
    return _window_detail(payload, "week", "week")


def _detail_jetbrains(payload):
    return _window_detail(payload, "month", "month")


def _detail_zed(payload):
    return _window_detail(payload, "predictions", "predictions")


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


def _detail_plausible(payload):
    if not payload.get("configured"):
        return payload.get("error") or "not connected"
    if not payload.get("ok"):
        return payload.get("error")
    count = payload.get("site_count") or 0
    live = payload.get("realtime") or 0
    today = payload.get("visitors_today") or 0
    label = payload.get("range_label") or "today"
    bits = [f"{count} site" + ("" if count == 1 else "s")]
    if live:
        bits.append(f"{live} live")
    bits.append(f"{today} {label}")
    return " · ".join(bits)


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


def _summary_copilot(payload):
    premium = (payload.get("premium") or {}).get("pct")
    chat = (payload.get("chat") or {}).get("pct")
    return f"plan={payload.get('plan')}  premium={premium}%  chat={chat}%"


def _summary_gemini(payload):
    pro = (payload.get("pro") or {}).get("pct")
    flash = (payload.get("flash") or {}).get("pct")
    return f"plan={payload.get('plan')}  pro={pro}%  flash={flash}%"


def _summary_windsurf(payload):
    session = (payload.get("session") or {}).get("pct")
    week = (payload.get("week") or {}).get("pct")
    return f"plan={payload.get('plan')}  day={session}%  week={week}%"


def _summary_jetbrains(payload):
    month = (payload.get("month") or {}).get("pct")
    return f"plan={payload.get('plan')}  month={month}%"


def _summary_zed(payload):
    preds = (payload.get("predictions") or {}).get("pct")
    return f"plan={payload.get('plan')}  predictions={preds}%"


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


def _summary_plausible(payload):
    return (f"sites={payload.get('site_count')} "
            f"live={payload.get('realtime')} "
            f"today={payload.get('visitors_today')}")


# ---------------- blank payloads (shape before the first fetch) ----------------

def _blank_quota():
    return {"ok": False, "plan": None, "session": None, "week": None}


def _blank_cursor():
    return {"ok": False, "plan": None, "auto": None, "api": None}


def _blank_copilot():
    return {"ok": False, "plan": None, "premium": None, "chat": None}


def _blank_gemini():
    return {"ok": False, "plan": None, "pro": None, "flash": None}


def _blank_jetbrains():
    return {"ok": False, "plan": None, "month": None}


def _blank_zed():
    return {"ok": False, "plan": None, "predictions": None}


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


def _blank_plausible():
    return {"ok": False, "configured": False, "sites": [],
            "site_count": 0, "visitors_today": 0, "realtime": 0,
            "range": "24h", "range_label": "24h"}


# Order matters — Mac Settings rows and the ESP32 footer dots follow it, and
# clients render groups in GROUP_IDS order, so keep AI rows first.
# Quota accents match firmware COL_CLAUDE / COL_OPENAI / COL_CURSOR.
_CLAUDE_POOLS = (
    PoolSpec("session", "session", "Session", oauth_usage.SESSION_WINDOW_S),
    PoolSpec("week", "week", "Weekly", oauth_usage.WEEK_WINDOW_S),
)
_CODEX_POOLS = (
    PoolSpec("session", "session", "Session", oauth_usage.SESSION_WINDOW_S),
    PoolSpec("week", "week", "Weekly", oauth_usage.WEEK_WINDOW_S),
)
_CURSOR_POOLS = (
    PoolSpec("total", "total", "Total"),
    PoolSpec("auto", "auto", "Auto", ring=False),
    PoolSpec("api", "api", "API"),
)
_COPILOT_POOLS = (
    PoolSpec("premium", "premium", "Premium", jetbrains_usage.MONTH_WINDOW_S),
    PoolSpec("chat", "chat", "Chat", jetbrains_usage.MONTH_WINDOW_S),
)
_GEMINI_POOLS = (
    PoolSpec("pro", "pro", "Pro", gemini_usage.DAY_WINDOW_S),
    PoolSpec("flash", "flash", "Flash", gemini_usage.DAY_WINDOW_S),
)
_WINDSURF_POOLS = (
    PoolSpec("session", "session", "Daily", windsurf_usage.DAY_WINDOW_S),
    PoolSpec("week", "week", "Weekly", windsurf_usage.WEEK_WINDOW_S),
)
_JETBRAINS_POOLS = (
    PoolSpec("month", "month", "Monthly", jetbrains_usage.MONTH_WINDOW_S),
)
_ZED_POOLS = (
    PoolSpec("predictions", "predictions", "Predictions",
             zed_usage.MONTH_WINDOW_S),
)

SOURCES = (
    Source("claude", "Claude", "Keychain / ~/.claude credentials", 60,
           oauth_usage.fetch_quota, _detail_claude, _summary_claude,
           _blank_quota, kind="quota", group=GROUP_AI, pools=_CLAUDE_POOLS,
           headline=("week", "session"), accent="#D97757"),
    Source("codex", "Codex", "~/.codex/auth.json", 60,
           codex_usage.fetch_quota, _detail_codex, _summary_codex,
           _blank_quota, kind="quota", group=GROUP_AI, pools=_CODEX_POOLS,
           headline=("week", "session"), accent="#10A37F"),
    Source("cursor", "Cursor", "Cursor IDE signed-in JWT", 60,
           cursor_usage.fetch_quota, _detail_cursor, _summary_cursor,
           _blank_cursor, kind="quota", group=GROUP_AI, pools=_CURSOR_POOLS,
           headline=("total",), headline_fallback_max=("auto", "api"),
           accent="#789BC8"),
    Source("copilot", "Copilot", "GitHub token / `gh auth`", 60,
           copilot_usage.fetch_quota, _detail_copilot, _summary_copilot,
           _blank_copilot, kind="quota", group=GROUP_AI, pools=_COPILOT_POOLS,
           headline=("premium", "chat"), accent="#A371F7"),
    Source("gemini", "Gemini", "~/.gemini OAuth (Gemini CLI)", 60,
           gemini_usage.fetch_quota, _detail_gemini, _summary_gemini,
           _blank_gemini, kind="quota", group=GROUP_AI, pools=_GEMINI_POOLS,
           headline=("pro", "flash"), accent="#4285F4"),
    Source("windsurf", "Windsurf", "Windsurf IDE plan cache", 60,
           windsurf_usage.fetch_quota, _detail_windsurf, _summary_windsurf,
           _blank_quota, kind="quota", group=GROUP_AI, pools=_WINDSURF_POOLS,
           headline=("week", "session"), accent="#00C2A8"),
    Source("jetbrains", "JetBrains AI", "Local AI Assistant quota XML", 60,
           jetbrains_usage.fetch_quota, _detail_jetbrains, _summary_jetbrains,
           _blank_jetbrains, kind="quota", group=GROUP_AI,
           pools=_JETBRAINS_POOLS, headline=("month",), accent="#FE315D"),
    Source("zed", "Zed", "Zed Keychain session", 60,
           zed_usage.fetch_quota, _detail_zed, _summary_zed,
           _blank_zed, kind="quota", group=GROUP_AI, pools=_ZED_POOLS,
           headline=("predictions",), accent="#084CCF"),
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
    Source("plausible", "Plausible", "Stats/Sites API key in Keychain",
           plausible_usage.CACHE_TTL_S,
           plausible_usage.fetch_stats, _detail_plausible, _summary_plausible,
           _blank_plausible),
)

BY_ID = {source.id: source for source in SOURCES}
SOURCE_IDS = tuple(source.id for source in SOURCES)

# Quota subset — pollers, daily burn, burndown samples, /usage providers[].
QUOTA_SOURCES = tuple(s for s in SOURCES if s.kind == "quota")
BURN_SOURCE_IDS = tuple(s.id for s in QUOTA_SOURCES)



def get(source_id):
    return BY_ID.get(source_id)


def group_of(source_id):
    source = BY_ID.get(source_id)
    return source.group if source else GROUP_DEVTOOLS


def sources_in_group(group):
    return tuple(s for s in SOURCES if s.group == group)


def is_quota(source_id):
    source = BY_ID.get(source_id)
    return bool(source and source.kind == "quota")


def meta_for(source_id):
    source = BY_ID.get(source_id)
    if source is None:
        return {"title": source_id, "hint": ""}
    return {"title": source.title, "hint": source.hint}


def headline_pct(source_id, payload):
    """Stable plan-window % used for daily burn accounting. None if unknown."""
    source = BY_ID.get(source_id)
    payload = payload or {}
    if source is None or source.kind != "quota":
        return None
    for key in source.headline:
        pct = (payload.get(key) or {}).get("pct")
        if pct is not None:
            try:
                return float(pct)
            except (TypeError, ValueError):
                continue
    vals = []
    for key in source.headline_fallback_max:
        pct = (payload.get(key) or {}).get("pct")
        if pct is None:
            continue
        try:
            vals.append(float(pct))
        except (TypeError, ValueError):
            continue
    return max(vals) if vals else None


def pool_rows():
    """Flat (provider, pool_id, key, default_window_s) for quota_samples."""
    rows = []
    for source in QUOTA_SOURCES:
        for pool in source.pools:
            rows.append((source.id, pool.id, pool.key, pool.default_window_s))
    return tuple(rows)


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
    """First-run defaults: only sources that look signed-in locally."""
    return detect_sources.suggested_enabled(
        SOURCE_IDS, quota_ids=BURN_SOURCE_IDS)


def _load():
    try:
        with open(STORE_PATH) as handle:
            data = json.load(handle)
    except FileNotFoundError:
        # Seed once so Claude-only machines don't poll empty Codex/Cursor.
        enabled = _default_enabled()
        state = {
            "enabled": enabled,
            "seeded_from": "detect",
            "detected": detect_sources.detected_map(),
        }
        try:
            _save(state)
        except OSError:
            pass
        return {"enabled": enabled}
    except (OSError, json.JSONDecodeError):
        return {"enabled": _default_enabled()}
    if not isinstance(data, dict):
        return {"enabled": _default_enabled()}
    enabled = {sid: False for sid in SOURCE_IDS}
    # Legacy files without an explicit map keep prior all-on behaviour only
    # when the key is missing entirely and the file has other content — but
    # normal files always have "enabled". Missing ids default off so new
    # sources don't surprise existing installs.
    raw = data.get("enabled") if isinstance(data.get("enabled"), dict) else {}
    if not raw and data.get("seeded_from") is None:
        # Pre-detect era file that somehow lacks enabled — treat as all on.
        return {"enabled": {sid: True for sid in SOURCE_IDS}}
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


def detection_payload():
    """Shape for GET /setup — what local probes found + current enables."""
    detected = detect_sources.detected_map()
    enabled = enabled_map()
    return {
        "detected": detected,
        "enabled": enabled,
        "groups": list(GROUP_IDS),
        "sources": [
            {
                "id": source.id,
                "title": source.title,
                "hint": source.hint,
                "kind": source.kind,
                "group": source.group,
                "detected": bool(detected.get(source.id, False)),
                "enabled": bool(enabled.get(source.id, False)),
            }
            for source in SOURCES
        ],
    }

def reset_for_tests():
    """Drop cached enabled flags (unit tests only)."""
    global _state
    with _lock:
        _state = None
