"""Trimmed /usage projection for the ESP32.

The full document is ~30KB and the board reads maybe a fifth of it. That cost
is invisible over Wi-Fi but brutal over USB CDC: 30KB at 115200 baud is ~2.6s
of wire time per poll, which is why the cable path needs multi-second timeouts
and why a sync visibly stalls the UI.

This projection keeps only fields `applyUsageJson()` actually consumes, caps
list lengths at what the firmware can store, and drops nulls (ArduinoJson can't
tell an absent key from a null one, and the firmware's `.isNull()` guards treat
them identically). Result is ~4KB.

One source of truth: row caps below must match MAX_* in firmware/src/main.cpp.
Stdlib only.
"""

from __future__ import annotations

# Mirror of firmware/src/main.cpp MAX_DEPLOYS / MAX_COMMITS / MAX_SERVERS.
MAX_DEPLOYS = 6
MAX_COMMITS = 6
MAX_SERVERS = 6
MAX_SOURCES = 8

CLAUDE_FIELDS = (
    "plan",
    "quota_ok",
    "session_pct",
    "session_pace_pct",
    "session_resets_in",
    "week_pct",
    "week_pace_pct",
    "week_resets_in",
)

CODEX_FIELDS = (
    "ok",
    "plan",
    "session_pct",
    "session_pace_pct",
    "session_resets_in",
    "week_pct",
    "week_pace_pct",
    "week_resets_in",
    "pace_label",
    "runs_out_in",
    "reset_credits_available",
    "reset_credits_expiries",
)

CURSOR_FIELDS = (
    "ok",
    "plan",
    "total_pct",
    "total_pace_pct",
    "auto_pct",
    "auto_pace_pct",
    "api_pct",
    "api_pace_pct",
    "resets_in",
    "pace_label",
    "on_demand_label",
)

# Burndown for the board: one pool per provider, and only the marks it draws.
# The ideal line is a straight run from (t0, 100) to (t1, 0), so it is derived
# on the board rather than sent. Keys are short because this rides CDC.
MAX_BURNDOWN_POINTS = 24
BURNDOWN_FIELDS = ("pool", "status", "t0", "t1", "pts", "proj", "warn", "est")
# Longest window wins — a weekly shape is worth a chart, a 5h session is noise
# at 368px. Cursor's pools tie on length, so precedence breaks it.
BURNDOWN_POOL_ORDER = ("week", "total", "auto", "api", "session")

DEPLOY_FIELDS = ("project", "status", "target", "ago", "branch")
COMMIT_FIELDS = ("repo", "subject", "ago", "branch")
SERVER_FIELDS = ("name", "port", "cmd")
SOURCE_FIELDS = ("id", "title", "enabled", "ok", "stale")


def _pick(src, fields):
    """Copy `fields` from src, skipping keys whose value is None."""
    src = src or {}
    return {k: src[k] for k in fields if src.get(k) is not None}


def _rows(items, fields, limit):
    out = []
    for item in (items or [])[:limit]:
        if isinstance(item, dict):
            out.append(_pick(item, fields))
    return out


def _thin(points, limit):
    """Keep at most `limit` points, evenly spaced, always keeping the newest."""
    points = [p for p in (points or []) if isinstance(p, (list, tuple)) and len(p) >= 2]
    if len(points) <= limit:
        return [[int(t), round(float(v), 1)] for t, v in points]
    step = (len(points) - 1) / float(limit - 1)
    picked = [points[int(round(i * step))] for i in range(limit)]
    if picked[-1] is not points[-1]:
        picked[-1] = points[-1]
    return [[int(t), round(float(v), 1)] for t, v in picked]


def _burndown_for(pools):
    """Pick one pool for the board and strip it to the drawable marks."""
    if not isinstance(pools, dict) or not pools:
        return None
    ordered = sorted(
        (p for p in pools.values() if isinstance(p, dict)),
        key=lambda p: (
            -(p.get("window_s") or 0),
            BURNDOWN_POOL_ORDER.index(p.get("pool"))
            if p.get("pool") in BURNDOWN_POOL_ORDER else len(BURNDOWN_POOL_ORDER),
        ),
    )
    if not ordered:
        return None
    best = ordered[0]
    if best.get("window_start") is None or best.get("window_end") is None:
        return None
    return {
        "pool": best.get("pool"),
        "status": best.get("status"),
        "t0": int(best["window_start"]),
        "t1": int(best["window_end"]),
        "pts": _thin(best.get("actual"), MAX_BURNDOWN_POINTS),
        "proj": _thin(best.get("projected"), 2),
        "warn": bool(best.get("exhausts_before_reset")),
        # Projection rests on the token-history estimate rather than measured
        # samples, so the board draws it more faintly.
        "est": best.get("rate_source") == "estimated",
    }


def build(doc):
    """Project a full rollup document down to the board's subset."""
    doc = doc or {}
    vercel = doc.get("vercel") or {}
    git = doc.get("git") or {}
    local = doc.get("local") or {}

    device = _pick(doc, CLAUDE_FIELDS)
    if doc.get("updated") is not None:
        device["updated"] = doc["updated"]

    device["codex"] = _pick(doc.get("codex"), CODEX_FIELDS)
    device["cursor"] = _pick(doc.get("cursor"), CURSOR_FIELDS)
    device["vercel"] = {
        "ok": bool(vercel.get("ok")),
        "deployments": _rows(
            vercel.get("deployments"), DEPLOY_FIELDS, MAX_DEPLOYS),
    }
    if vercel.get("team"):
        device["vercel"]["team"] = vercel["team"]
    device["git"] = {
        "ok": bool(git.get("ok")),
        "commits": _rows(git.get("commits"), COMMIT_FIELDS, MAX_COMMITS),
    }
    device["local"] = {
        "ok": bool(local.get("ok")),
        "servers": _rows(local.get("servers"), SERVER_FIELDS, MAX_SERVERS),
    }
    if local.get("host"):
        device["local"]["host"] = local["host"]
    device["sources"] = _rows(
        doc.get("sources"), SOURCE_FIELDS, MAX_SOURCES)

    burndown = {}
    for provider, pools in (doc.get("burndown") or {}).items():
        trimmed = _burndown_for(pools)
        if trimmed is not None:
            burndown[provider] = trimmed
    if burndown:
        device["burndown"] = burndown
    return device
