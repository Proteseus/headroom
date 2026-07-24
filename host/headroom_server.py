#!/usr/bin/env python3
"""headroom — Claude + Codex + Cursor (+ Vercel + Git + GitHub + Local) desk host.

Parses ~/.claude/projects/**/*.jsonl (the same usage logs `ccusage` reads),
aggregates token counts and cost into rolling time windows, and serves a flat
JSON document at GET http://<mac>:8737/usage for a Waveshare ESP32-S3 to poll
(Wi-Fi), with a best-effort USB CDC fallback (HR framed protocol) in-process.

Also polls Anthropic OAuth, OpenAI Codex (wham/usage), and Cursor
(GetCurrentPeriodUsage) quotas, Vercel team deployments, local git activity,
GitHub Actions failures, and listening local servers so the desk gadget can
flip pages.

Zero dependencies — Python 3 standard library only. Incremental: each file's
byte offset is remembered so a poll only reads newly-appended lines instead of
rescanning every file.

Run:  python3 headroom_server.py [--port 8737] [--interval 15]
"""

import argparse
import concurrent.futures
import ipaddress
import json
import os
import sys
import threading
import time
import urllib.parse
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
from glob import glob
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pricing
import oauth_usage
import codex_usage
import cursor_usage
import vercel_builds
import git_activity
import github_actions
import local_servers
import supabase_usage
import daily_burn
import sources_config
import app_config
import usb_bridge

LOG_ROOT = os.path.expanduser("~/.claude/projects")
RETENTION_S = 7 * 24 * 3600  # keep events long enough for the weekly window
QUOTA_POLL_S = 60  # usage endpoints are rate-limited; don't hammer them
SUPABASE_POLL_S = 5 * 60
GITHUB_POLL_S = 90
BOOT_T0 = time.time()


def _local_tz():
    try:
        return ZoneInfo(app_config.timezone_name())
    except Exception:
        return ZoneInfo("UTC")

_lock = threading.Lock()
_offsets = {}   # filepath -> bytes already consumed
_events = []    # list of dicts: {t, model, in, out, cr, w5, w1, cost}
_quota = {"ok": False, "plan": None, "session": None, "week": None}
_codex = {"ok": False, "plan": None, "session": None, "week": None}
_cursor = {"ok": False, "plan": None, "auto": None, "api": None}
_vercel = {"ok": False, "team": None, "deployments": []}
_git = {"ok": False, "commits": []}
_github = {
    "ok": False, "configured": False, "runs": [],
    "fail_count": 0, "running_count": 0, "error": None,
}
_local = {"ok": False, "host": None, "servers": []}
_supabase = {
    "ok": False, "configured": False, "projects": [],
    "project_count": 0, "healthy_count": 0, "alert_count": 0,
}
# Last successful (or attempted) refresh timestamps for /usage → sources.
_source_times = {sid: 0.0 for sid in sources_config.SOURCE_IDS}


def _unix_seconds(value):
    try:
        value = float(value)
        return value / 1000.0 if value > 1e12 else value
    except (TypeError, ValueError):
        return 0.0


def _build_activity(vercel, git, supabase=None, github=None):
    """Merge deploys, commits, Actions failures, and backend alerts."""
    deployments = vercel.get("deployments") or []
    commits = git.get("commits") or []
    deployed_shas = {d.get("sha") for d in deployments if d.get("sha")}
    items = []

    for deployment in deployments:
        state = deployment.get("status") or "unknown"
        items.append({
            "id": deployment.get("id") or "|".join(filter(None, [
                deployment.get("project"),
                deployment.get("sha"),
                str(deployment.get("created_at") or ""),
            ])),
            "kind": "deployment",
            "status": state,
            "subject": (deployment.get("commit_message")
                        or deployment.get("project")
                        or "Deployment"),
            "repo": deployment.get("repo") or deployment.get("project"),
            "project": deployment.get("project"),
            "branch": deployment.get("branch"),
            "sha": deployment.get("sha"),
            "short_sha": deployment.get("short_sha"),
            "target": deployment.get("target"),
            "created_at": _unix_seconds(deployment.get("created_at")),
            "ago": deployment.get("ago"),
            "error_message": deployment.get("error_message"),
            "url": deployment.get("url"),
            "inspector_url": deployment.get("inspector_url"),
        })

    for commit in commits:
        if commit.get("sha") in deployed_shas:
            continue
        pushed = commit.get("pushed")
        status = "pushed" if pushed is True else (
            "local" if pushed is False else "committed")
        items.append({
            "id": commit.get("sha") or "|".join(filter(None, [
                commit.get("repo"),
                commit.get("subject"),
                str(commit.get("created_at") or ""),
            ])),
            "kind": "commit",
            "status": status,
            "subject": commit.get("subject") or "Commit",
            "repo": commit.get("repo"),
            "project": None,
            "branch": commit.get("branch"),
            "sha": commit.get("sha"),
            "short_sha": commit.get("short_sha"),
            "target": None,
            "created_at": _unix_seconds(commit.get("created_at")),
            "ago": commit.get("ago"),
            "error_message": None,
            "url": commit.get("repo_url"),
            "inspector_url": None,
        })

    github = github or {}
    for run in (github.get("runs") or [])[:8]:
        status = run.get("status") or "failure"
        subject = run.get("display_title") or run.get("name") or "Workflow"
        items.append({
            "id": f"github:{run.get('id')}",
            "kind": "github",
            "status": status,
            "subject": subject,
            "repo": run.get("repo"),
            "project": run.get("name"),
            "branch": run.get("branch"),
            "sha": run.get("sha"),
            "short_sha": run.get("short_sha"),
            "target": None,
            "created_at": _unix_seconds(run.get("created_at")),
            "ago": run.get("ago"),
            "error_message": (
                f"{run.get('repo')} · {status}"
                if run.get("repo") else status
            ),
            "url": run.get("url"),
            "inspector_url": run.get("url"),
        })

    supabase = supabase or {}
    supabase_alerts = [
        project for project in (supabase.get("projects") or [])
        if not project.get("healthy")
    ][:5]
    for project in supabase_alerts:
        failed = project.get("unhealthy_services") or []
        detail = ", ".join(failed) if failed else (
            project.get("status") or project.get("health_error")
            or "health unavailable")
        items.append({
            "id": f"supabase:{project.get('ref') or project.get('name')}",
            "kind": "supabase",
            "status": "error",
            "subject": f"{project.get('name') or 'Supabase'} needs attention",
            "repo": "Supabase",
            "project": project.get("name"),
            "branch": None,
            "sha": None,
            "short_sha": None,
            "target": None,
            "created_at": supabase.get("updated_at") or time.time(),
            "ago": "now",
            "error_message": detail,
            "url": project.get("dashboard_url"),
            "inspector_url": project.get("dashboard_url"),
        })

    items.sort(key=lambda item: item.get("created_at") or 0, reverse=True)
    return items[:14]


def _parse_ts(rec):
    ts = rec.get("timestamp")
    if not ts:
        return None
    try:
        # e.g. 2026-07-21T05:41:00.000Z
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _event_from(rec, now):
    """Turn one assistant log record into a token event, or None."""
    msg = rec.get("message") or {}
    usage = msg.get("usage")
    if not usage:
        return None
    t = _parse_ts(rec)
    if t is None or t < now - RETENTION_S:
        return None

    inp = usage.get("input_tokens", 0) or 0
    out = usage.get("output_tokens", 0) or 0
    cr = usage.get("cache_read_input_tokens", 0) or 0
    cc = usage.get("cache_creation") or {}
    w5 = cc.get("ephemeral_5m_input_tokens", 0) or 0
    w1 = cc.get("ephemeral_1h_input_tokens", 0) or 0
    # Fall back to the flat field if the breakdown is absent (older records).
    if not (w5 or w1):
        w5 = usage.get("cache_creation_input_tokens", 0) or 0

    model = msg.get("model") or "unknown"
    cost = pricing.cost_usd(
        model, input_tokens=inp, output_tokens=out,
        cache_read=cr, cache_write_5m=w5, cache_write_1h=w1,
    )
    return {"t": t, "model": model, "in": inp, "out": out,
            "cr": cr, "w5": w5, "w1": w1, "cost": cost}


def _read_file(path, from_offset, now):
    """Read a jsonl file from a byte offset; return (events, new_offset)."""
    events = []
    try:
        with open(path, "rb") as fh:
            fh.seek(from_offset)
            data = fh.read()
            new_offset = fh.tell()
    except OSError:
        return events, from_offset

    # Only consume up to the last complete line; leave a partial tail for next time.
    last_nl = data.rfind(b"\n")
    if last_nl == -1:
        return events, from_offset  # no complete line yet
    consumed = data[: last_nl + 1]
    new_offset = from_offset + len(consumed)

    for line in consumed.splitlines():
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
        ev = _event_from(rec, now)
        if ev:
            events.append(ev)
    return events, new_offset


def scan():
    """Incrementally ingest new log lines and prune stale events."""
    now = time.time()
    fresh = []
    for path in glob(os.path.join(LOG_ROOT, "**", "*.jsonl"), recursive=True):
        off = _offsets.get(path, 0)
        # Handle truncation/rotation: if the file shrank, start over.
        try:
            size = os.path.getsize(path)
        except OSError:
            continue
        if size < off:
            off = 0
        evs, new_off = _read_file(path, off, now)
        _offsets[path] = new_off
        fresh.extend(evs)

    with _lock:
        _events.extend(fresh)
        cutoff = now - RETENTION_S
        _events[:] = [e for e in _events if e["t"] >= cutoff]


def _blank():
    return {"input": 0, "output": 0, "cache_read": 0,
            "cache_write": 0, "total": 0, "cost_usd": 0.0}


def _accumulate(bucket, e):
    bucket["input"] += e["in"]
    bucket["output"] += e["out"]
    bucket["cache_read"] += e["cr"]
    bucket["cache_write"] += e["w5"] + e["w1"]
    bucket["total"] += e["in"] + e["out"] + e["cr"] + e["w5"] + e["w1"]
    bucket["cost_usd"] += e["cost"]


def _flatten_codex(codex):
    """CodexBar-style flat fields for the ESP32 Codex page."""
    session_q = codex.get("session") or {}
    week_q = codex.get("week") or {}
    pace = codex.get("pace") or {}
    credits = codex.get("reset_credits") or {}
    spend = codex.get("spend") or {}
    session_resets = session_q.get("resets_in_s")
    week_resets = week_q.get("resets_in_s")
    session_window = session_q.get("window_s") or oauth_usage.SESSION_WINDOW_S
    week_window = week_q.get("window_s") or oauth_usage.WEEK_WINDOW_S
    return {
        "ok": bool(codex.get("ok")),
        "plan": codex.get("plan"),
        "error": codex.get("error"),
        "session_pct": session_q.get("pct"),
        "session_pace_pct": oauth_usage.pace_pct(session_resets, session_window),
        "session_resets_in_s": session_resets,
        "session_resets_in": codex_usage.fmt_resets(session_resets),
        "week_pct": week_q.get("pct"),
        "week_pace_pct": oauth_usage.pace_pct(week_resets, week_window),
        "week_resets_in_s": week_resets,
        "week_resets_in": codex_usage.fmt_resets(week_resets),
        "pace_label": pace.get("label"),
        "pace_delta_pct": pace.get("delta_pct"),
        "pace_in_deficit": pace.get("in_deficit"),
        "runs_out_in": pace.get("runs_out_in"),
        "runs_out_in_s": pace.get("runs_out_in_s"),
        "reset_credits_available": credits.get("available"),
        "reset_credits_expiries": credits.get("expiries") or [],
        "cost_usd": spend.get("used_usd"),
        "cost_limit_usd": spend.get("limit_usd"),
        "cost_remaining_usd": spend.get("remaining_usd"),
        "cost_label": spend.get("label"),
        "cost_reached": spend.get("reached"),
    }


def _flatten_cursor(cursor):
    """Flat Total/Auto/API fields for the ESP32 and menu-bar Cursor views."""
    total_q = cursor.get("total") or {}
    auto_q = cursor.get("auto") or {}
    api_q = cursor.get("api") or {}
    pace = cursor.get("pace") or {}
    spend = cursor.get("spend") or {}
    on_demand = cursor.get("on_demand") or {}
    auto_resets = auto_q.get("resets_in_s")
    api_resets = api_q.get("resets_in_s")
    # Both pools share the billing cycle; fall back to top-level.
    resets = (
        cursor.get("resets_in_s")
        if cursor.get("resets_in_s") is not None
        else (auto_resets if auto_resets is not None else api_resets)
    )
    auto_window = auto_q.get("window_s") or 0
    api_window = api_q.get("window_s") or auto_window
    return {
        "ok": bool(cursor.get("ok")),
        "plan": cursor.get("plan"),
        "error": cursor.get("error"),
        "total_pct": total_q.get("pct"),
        "total_pace_pct": oauth_usage.pace_pct(
            total_q.get("resets_in_s"), total_q.get("window_s"))
        if total_q.get("window_s") else None,
        "auto_pct": auto_q.get("pct"),
        "auto_pace_pct": oauth_usage.pace_pct(auto_resets, auto_window)
        if auto_window else None,
        "api_pct": api_q.get("pct"),
        "api_pace_pct": oauth_usage.pace_pct(api_resets, api_window)
        if api_window else None,
        "resets_in_s": resets,
        "resets_in": oauth_usage.fmt_resets(resets),
        "pace_label": pace.get("label"),
        "pace_delta_pct": pace.get("delta_pct"),
        "pace_in_deficit": pace.get("in_deficit"),
        "cost_usd": spend.get("used_usd"),
        "cost_limit_usd": spend.get("limit_usd"),
        "cost_remaining_usd": spend.get("remaining_usd"),
        "cost_label": spend.get("label"),
        "on_demand_label": on_demand.get("label"),
        "on_demand_remaining_usd": on_demand.get("remaining_usd"),
        "on_demand_limit_usd": on_demand.get("limit_usd"),
        "on_demand_used_usd": on_demand.get("used_usd"),
    }


def rollup():
    """Compute the flat JSON document served at /usage."""
    now = time.time()
    local_midnight = datetime.now().astimezone().replace(
        hour=0, minute=0, second=0, microsecond=0).timestamp()

    today, week, session_5h, last_hour = _blank(), _blank(), _blank(), _blank()
    by_model = {}

    with _lock:
        events = list(_events)
        quota = dict(_quota)
        codex = dict(_codex)
        cursor = dict(_cursor)
        vercel = dict(_vercel)
        git = dict(_git)
        github = dict(_github)
        local = dict(_local)
        supabase = dict(_supabase)

    for e in events:
        t = e["t"]
        if t >= now - 7 * 24 * 3600:
            _accumulate(week, e)
        if t >= local_midnight:
            _accumulate(today, e)
            bm = by_model.setdefault(e["model"], _blank())
            _accumulate(bm, e)
        if t >= now - 5 * 3600:
            _accumulate(session_5h, e)
        if t >= now - 3600:
            _accumulate(last_hour, e)

    for b in (today, week, session_5h, last_hour, *by_model.values()):
        b["cost_usd"] = round(b["cost_usd"], 4)

    local_tz = _local_tz()
    flat_codex = _flatten_codex(codex)
    flat_cursor = _flatten_cursor(cursor)
    activity = _build_activity(vercel, git, supabase, github)
    sources = _sources_payload(
        quota, codex, cursor, vercel, git, github, local, supabase)
    # Flatten Claude fields at the top level (back-compat with older firmware).
    session_q = quota.get("session") or {}
    week_q = quota.get("week") or {}
    session_resets = session_q.get("resets_in_s")
    week_resets = week_q.get("resets_in_s")
    doc = {
        "updated": datetime.now(local_tz).strftime("%Y-%m-%dT%H:%M:%S%z"),
        "plan": quota.get("plan"),
        "session_pct": session_q.get("pct"),
        "session_pace_pct": oauth_usage.pace_pct(
            session_resets, oauth_usage.SESSION_WINDOW_S),
        "session_resets_in_s": session_resets,
        "session_resets_in": oauth_usage.fmt_resets(session_resets),
        "week_pct": week_q.get("pct"),
        "week_pace_pct": oauth_usage.pace_pct(
            week_resets, oauth_usage.WEEK_WINDOW_S),
        "week_resets_in_s": week_resets,
        "week_resets_in": oauth_usage.fmt_resets(week_resets),
        "quota_ok": bool(quota.get("ok")),
        "quota_error": quota.get("error"),
        "today": today,
        "week": week,
        "session_5h": session_5h,
        "last_hour": last_hour,
        "by_model": by_model,
        "by_day": daily_burn.series(tz=local_tz),
        "quota": quota,
        "codex": flat_codex,
        "cursor": flat_cursor,
        "vercel": {
            "ok": bool(vercel.get("ok")),
            "team": vercel.get("team"),
            "error": vercel.get("error"),
            "stale": bool(vercel.get("stale")),
            "deployments": vercel.get("deployments") or [],
        },
        "git": {
            "ok": bool(git.get("ok")),
            "error": git.get("error"),
            "stale": bool(git.get("stale")),
            "commits": git.get("commits") or [],
        },
        "activity": activity,
        "supabase": supabase,
        "github": {
            "ok": bool(github.get("ok")),
            "configured": bool(github.get("configured")),
            "error": github.get("error"),
            "stale": bool(github.get("stale")),
            "fail_count": github.get("fail_count") or 0,
            "running_count": github.get("running_count") or 0,
            "runs": github.get("runs") or [],
            "repos": github.get("repos") or [],
        },
        "local": {
            "ok": bool(local.get("ok")),
            "host": local.get("host"),
            "error": local.get("error"),
            "stale": bool(local.get("stale")),
            "servers": local.get("servers") or [],
        },
        "sources": sources,
    }
    doc["attention"] = _build_attention(doc)
    return doc


def _build_attention(doc):
    """Single glance score for menu-bar warning light + Overview card."""
    reasons = []

    def add(level, kind, summary, weight):
        reasons.append({
            "level": level,
            "kind": kind,
            "summary": summary,
            "weight": weight,
        })

    github = doc.get("github") or {}
    if github.get("configured") and (github.get("fail_count") or 0) > 0:
        fails = int(github["fail_count"])
        add(
            "critical",
            "github",
            f"{fails} GitHub Actions failure" + ("" if fails == 1 else "s"),
            40 + min(30, fails * 5),
        )

    supabase = doc.get("supabase") or {}
    if supabase.get("configured") and (supabase.get("alert_count") or 0) > 0:
        alerts = int(supabase["alert_count"])
        add(
            "warn" if alerts < 3 else "critical",
            "supabase",
            f"{alerts} Supabase alert" + ("" if alerts == 1 else "s"),
            25 + min(25, alerts * 8),
        )

    deploys = ((doc.get("vercel") or {}).get("deployments")) or []
    deploy_errors = sum(
        1 for d in deploys
        if (d.get("status") or "").lower() == "error"
        or (d.get("state") or "").upper() in ("ERROR", "FAILED")
    )
    if deploy_errors:
        add(
            "critical" if deploy_errors >= 2 else "warn",
            "vercel",
            f"{deploy_errors} failed deploy" + ("" if deploy_errors == 1 else "s"),
            20 + min(20, deploy_errors * 8),
        )

    # Quota % lives on the rings — don't nag Attention for a drained meter.
    # Only call out time-sensitive / hard-limit events.
    codex = doc.get("codex") or {}
    if codex.get("ok"):
        runs_out = codex.get("runs_out_in_s")
        if isinstance(runs_out, (int, float)) and 0 < runs_out <= 3 * 3600:
            add("warn", "codex", f"Codex runs out in {codex.get('runs_out_in')}", 22)
        if codex.get("cost_reached"):
            add("critical", "codex", "Codex spend limit reached", 40)

    # Source timeouts keep last-good data — don't light Attention for them.

    score = min(100, sum(r["weight"] for r in reasons))
    if any(r["level"] == "critical" for r in reasons):
        level = "critical"
    elif reasons:
        level = "warn"
    else:
        level = "ok"
    # Drop weight from public payload — clients only need level/summary.
    public_reasons = [
        {"level": r["level"], "kind": r["kind"], "summary": r["summary"]}
        for r in sorted(reasons, key=lambda r: -r["weight"])
    ]
    return {
        "level": level,
        "score": score,
        "summary": (
            public_reasons[0]["summary"] if public_reasons
            else "All clear"
        ),
        "reasons": public_reasons,
    }


def _source_detail(source_id, payload):
    if source_id == "claude":
        plan = payload.get("plan")
        week = (payload.get("week") or {}).get("pct")
        if plan and week is not None:
            return f"{plan} · week {week:.0f}%"
        return plan or payload.get("error")
    if source_id == "codex":
        plan = payload.get("plan")
        week = (payload.get("week") or {}).get("pct")
        if plan and week is not None:
            return f"{plan} · week {week:.0f}%"
        return plan or payload.get("error")
    if source_id == "cursor":
        plan = payload.get("plan")
        total = (payload.get("total") or {}).get("pct")
        if plan and total is not None:
            return f"{plan} · total {total:.0f}%"
        return plan or payload.get("error")
    if source_id == "vercel":
        team = payload.get("team")
        n = len(payload.get("deployments") or [])
        if team:
            return f"{team} · {n} deploys"
        return payload.get("error")
    if source_id == "git":
        n = len(payload.get("commits") or [])
        return f"{n} commits" if payload.get("ok") else payload.get("error")
    if source_id == "github":
        if not payload.get("configured"):
            return payload.get("error") or "not connected"
        fails = payload.get("fail_count") or 0
        running = payload.get("running_count") or 0
        if fails or running:
            bits = []
            if fails:
                bits.append(f"{fails} failed")
            if running:
                bits.append(f"{running} running")
            return " · ".join(bits)
        return "all clear"
    if source_id == "local":
        n = len(payload.get("servers") or [])
        host = payload.get("host")
        if payload.get("ok"):
            return f"{host or 'local'} · {n} servers"
        return payload.get("error")
    if source_id == "supabase":
        if not payload.get("configured"):
            return payload.get("error") or "not connected"
        alerts = payload.get("alert_count") or 0
        count = payload.get("project_count") or 0
        if alerts:
            return f"{count} projects · {alerts} alerts"
        return f"{count} projects"
    return payload.get("error")


def _sources_payload(quota, codex, cursor, vercel, git, github, local, supabase):
    enabled = sources_config.enabled_map()
    now = time.time()
    with _lock:
        times = dict(_source_times)
    bags = {
        "claude": quota,
        "codex": codex,
        "cursor": cursor,
        "vercel": vercel,
        "git": git,
        "github": github,
        "local": local,
        "supabase": supabase,
    }
    rows = []
    for sid in sources_config.SOURCE_IDS:
        meta = sources_config.meta_for(sid)
        payload = bags.get(sid) or {}
        age = times.get(sid) or 0.0
        rows.append({
            "id": sid,
            "title": meta["title"],
            "hint": meta["hint"],
            "enabled": bool(enabled.get(sid, True)),
            "ok": bool(payload.get("ok")),
            "stale": bool(payload.get("stale")),
            "configured": payload.get("configured"),
            "error": payload.get("error"),
            "detail": _source_detail(sid, payload),
            "age_s": (int(max(0, now - age)) if age > 0 else None),
        })
    return rows


def _health_payload():
    doc = rollup()
    sources = doc.get("sources") or []
    by_id = {row["id"]: row for row in sources}
    return {
        "ok": True,
        "uptime_s": int(max(0, time.time() - BOOT_T0)),
        "updated": doc.get("updated"),
        "sources": {
            sid: {
                "ok": by_id.get(sid, {}).get("ok"),
                "stale": by_id.get(sid, {}).get("stale"),
                "enabled": by_id.get(sid, {}).get("enabled"),
                "age_s": by_id.get(sid, {}).get("age_s"),
                "error": by_id.get(sid, {}).get("error"),
                "detail": by_id.get(sid, {}).get("detail"),
            }
            for sid in sources_config.SOURCE_IDS
        },
    }


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _is_loopback(self):
        try:
            address = ipaddress.ip_address(self.client_address[0])
            mapped = getattr(address, "ipv4_mapped", None)
            return address.is_loopback or bool(mapped and mapped.is_loopback)
        except ValueError:
            return False

    def _is_private(self):
        """Loopback or RFC1918 — desk gadgets on the LAN may force a sync."""
        try:
            address = ipaddress.ip_address(self.client_address[0])
            mapped = getattr(address, "ipv4_mapped", None)
            candidate = mapped or address
            return candidate.is_loopback or candidate.is_private
        except ValueError:
            return False

    def do_GET(self):
        path = self.path.rstrip("/")
        if path in ("", "/usage"):
            self._send_json(200, rollup())
        elif path == "/health":
            self._send_json(200, _health_payload())
        else:
            self.send_error(404)

    def do_POST(self):
        path = urllib.parse.urlsplit(self.path).path.rstrip("/")
        if path not in (
            "/local/stop",
            "/supabase/refresh",
            "/sync/refresh",
            "/sources",
        ):
            self.send_error(404)
            return
        # Config + process control stay Mac-only; sync refresh is LAN-ok so
        # the ESP32 long-press can poke the same Sources pipeline.
        if path == "/sync/refresh":
            if not self._is_private():
                self._send_json(403, {"ok": False, "error": "private network only"})
                return
        elif not self._is_loopback():
            self._send_json(403, {"ok": False, "error": "localhost only"})
            return
        if not self.headers.get("Content-Type", "").lower().startswith(
                "application/json"):
            self._send_json(415, {"ok": False, "error": "JSON required"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 4096:
                raise ValueError
            payload = json.loads(self.rfile.read(length))
        except (ValueError, json.JSONDecodeError, UnicodeDecodeError):
            self._send_json(400, {"ok": False, "error": "invalid request"})
            return

        if path == "/sources":
            enabled = payload.get("enabled")
            if not isinstance(enabled, dict):
                self._send_json(400, {"ok": False, "error": "enabled map required"})
                return
            result = sources_config.set_enabled(enabled)
            # Kick a refresh so ESP32/Mac see the change quickly.
            threading.Thread(
                target=_refresh_selected,
                kwargs={"sources": [
                    sid for sid, on in result.items() if on
                ], "force": True},
                daemon=True,
            ).start()
            self._send_json(200, {"ok": True, "enabled": result})
            return

        if path in ("/supabase/refresh", "/sync/refresh"):
            wanted = payload.get("sources")
            if path == "/supabase/refresh":
                wanted = ["supabase"]
            elif not isinstance(wanted, list) or not wanted:
                wanted = list(sources_config.SOURCE_IDS)
            wanted = [
                sid for sid in wanted
                if sid in sources_config.SOURCE_IDS
            ]
            threading.Thread(
                target=_refresh_selected,
                kwargs={"sources": wanted, "force": True},
                daemon=True,
            ).start()
            self._send_json(202, {"ok": True, "sources": wanted})
            return

        result = local_servers.stop_server(
            payload.get("pid"), payload.get("port"))
        if result.get("ok"):
            time.sleep(0.2)
            _refresh_one("local", force=True)
            self._send_json(200, result)
        else:
            self._send_json(409, result)

    def log_message(self, *args):
        pass  # quiet; this is a desk gadget, not a web server


def _mark_source(source_id):
    with _lock:
        _source_times[source_id] = time.time()


def _refresh_one(source_id, force=False):
    """Fetch one source and store it. Never raises."""
    global _quota, _codex, _cursor, _vercel, _git, _github, _local, _supabase
    try:
        if source_id == "claude":
            q = oauth_usage.fetch_quota(force=force)
            with _lock:
                _quota = q
            _mark_source("claude")
            if q.get("ok"):
                s = q.get("session") or {}
                w = q.get("week") or {}
                print(f"claude ok  plan={q.get('plan')}  "
                      f"session={s.get('pct')}%  week={w.get('pct')}%"
                      f"{'  stale' if q.get('stale') else ''}")
            else:
                print("claude miss:", q.get("error"))
        elif source_id == "codex":
            c = codex_usage.fetch_quota(force=force)
            with _lock:
                _codex = c
            _mark_source("codex")
            if c.get("ok"):
                s = c.get("session") or {}
                w = c.get("week") or {}
                pace = (c.get("pace") or {}).get("label") or "-"
                credits = (c.get("reset_credits") or {}).get("available")
                print(f"codex ok   plan={c.get('plan')}  "
                      f"session={s.get('pct')}%  week={w.get('pct')}%  "
                      f"pace={pace}  credits={credits}"
                      f"{'  stale' if c.get('stale') else ''}")
            else:
                print("codex miss:", c.get("error"))
        elif source_id == "cursor":
            cu = cursor_usage.fetch_quota(force=force)
            with _lock:
                _cursor = cu
            _mark_source("cursor")
            if cu.get("ok"):
                a = cu.get("auto") or {}
                p = cu.get("api") or {}
                print(f"cursor ok  plan={cu.get('plan')}  "
                      f"auto={a.get('pct')}%  api={p.get('pct')}%  "
                      f"resets={cu.get('resets_in_s')}"
                      f"{'  stale' if cu.get('stale') else ''}")
            else:
                print("cursor miss:", cu.get("error"))
        elif source_id == "vercel":
            v = vercel_builds.fetch_deployments(force=force)
            with _lock:
                _vercel = v
            _mark_source("vercel")
            if v.get("ok"):
                n = len(v.get("deployments") or [])
                print(f"vercel ok  team={v.get('team')}  deploys={n}"
                      f"{'  stale' if v.get('stale') else ''}")
            else:
                print("vercel miss:", v.get("error"))
        elif source_id == "git":
            g = git_activity.fetch_commits(force=force)
            with _lock:
                _git = g
            _mark_source("git")
            if g.get("ok"):
                n = len(g.get("commits") or [])
                print(f"git ok     commits={n}"
                      f"{'  stale' if g.get('stale') else ''}")
            else:
                print("git miss:", g.get("error"))
        elif source_id == "github":
            data = github_actions.fetch_actions(force=force)
            with _lock:
                _github = data
            _mark_source("github")
            if data.get("ok"):
                print(
                    f"github ok  fails={data.get('fail_count')}  "
                    f"running={data.get('running_count')}  "
                    f"repos={len(data.get('repos') or [])}"
                    f"{'  stale' if data.get('stale') else ''}"
                )
            else:
                print("github miss:", data.get("error"))
        elif source_id == "local":
            loc = local_servers.fetch_servers(force=force)
            with _lock:
                _local = loc
            _mark_source("local")
            if loc.get("ok"):
                n = len(loc.get("servers") or [])
                print(f"local ok   host={loc.get('host')}  servers={n}"
                      f"{'  stale' if loc.get('stale') else ''}")
            else:
                print("local miss:", loc.get("error"))
        elif source_id == "supabase":
            data = supabase_usage.fetch_projects(force=force)
            with _lock:
                _supabase = data
            _mark_source("supabase")
            if data.get("ok"):
                print(
                    f"supabase ok projects={data.get('project_count')} "
                    f"alerts={data.get('alert_count')}"
                    f"{'  stale' if data.get('stale') else ''}"
                )
            else:
                print("supabase miss:", data.get("error"))
    except Exception as exc:
        print(f"{source_id} error:", exc)


def _observe_burn():
    try:
        with _lock:
            q = dict(_quota)
            c = dict(_codex)
            cu = dict(_cursor)
        today_burn = daily_burn.observe(q, c, cu, tz=_local_tz())
        print(
            "burn today "
            f"claude={today_burn.get('claude')}%  "
            f"codex={today_burn.get('codex')}%  "
            f"cursor={today_burn.get('cursor')}%"
        )
    except Exception as exc:
        print("daily_burn error:", exc)


def _refresh_selected(sources, force=False):
    """Refresh the given sources in parallel (enabled filter still applies)."""
    enabled = sources_config.enabled_map()
    wanted = [
        sid for sid in sources
        if sid in sources_config.SOURCE_IDS and enabled.get(sid, True)
    ]
    if not wanted:
        return
    with concurrent.futures.ThreadPoolExecutor(
            max_workers=min(8, len(wanted))) as pool:
        list(pool.map(
            lambda sid: _refresh_one(sid, force=force),
            wanted,
        ))
    if any(sid in ("claude", "codex", "cursor") for sid in wanted):
        _observe_burn()


def _refresh_quotas(force=False):
    """Pull enabled Claude/Codex/Cursor/Vercel/git/local in parallel."""
    enabled = sources_config.enabled_map()
    batch = [
        sid for sid in ("claude", "codex", "cursor", "vercel", "git", "local")
        if enabled.get(sid, True)
    ]
    _refresh_selected(batch, force=force)


def _refresh_local(force=False):
    if sources_config.is_enabled("local"):
        _refresh_one("local", force=force)


def _refresh_supabase(force=False):
    if sources_config.is_enabled("supabase"):
        _refresh_one("supabase", force=force)


def _refresh_github(force=False):
    if sources_config.is_enabled("github"):
        _refresh_one("github", force=force)


def _rotate_logs():
    """Keep LaunchAgent logs from growing forever."""
    folder = os.path.expanduser("~/.headroom/logs")
    os.makedirs(folder, exist_ok=True)
    limit = 5 * 1024 * 1024
    for name in ("headroom.log", "headroom.err"):
        path = os.path.join(folder, name)
        try:
            size = os.path.getsize(path)
        except OSError:
            continue
        if size < limit:
            continue
        try:
            os.replace(path, path + ".1")
        except OSError:
            pass


def _poller(interval):
    last_quota = 0.0
    last_local = 0.0
    last_supabase = 0.0
    last_github = 0.0
    while True:
        try:
            scan()
        except Exception as exc:  # keep the daemon alive across odd records
            print("scan error:", exc)
        now = time.time()
        if now - last_local >= local_servers.CACHE_TTL_S:
            last_local = now
            _refresh_local()
        if now - last_supabase >= SUPABASE_POLL_S:
            last_supabase = now
            _refresh_supabase()
        if now - last_github >= GITHUB_POLL_S:
            last_github = now
            _refresh_github()
        if now - last_quota >= QUOTA_POLL_S:
            last_quota = now
            _refresh_quotas()
        time.sleep(interval)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8737)
    ap.add_argument("--interval", type=int, default=15,
                    help="seconds between log rescans")
    args = ap.parse_args()

    # Unbuffered logs under LaunchAgent redirects.
    try:
        sys.stdout.reconfigure(line_buffering=True)
        sys.stderr.reconfigure(line_buffering=True)
    except Exception:
        pass

    _rotate_logs()
    print(f"Bootstrapping from {LOG_ROOT} ...", flush=True)
    t0 = time.time()
    scan()
    with _lock:
        n = len(_events)
    print(f"  {n} events in the last 7 days ({time.time()-t0:.1f}s)", flush=True)

    def _warmup():
        print("Refreshing enabled sources ...", flush=True)
        try:
            _refresh_quotas(force=True)
            _refresh_supabase(force=True)
            _refresh_github(force=True)
        except Exception as exc:
            print("warmup error:", exc, flush=True)

    threading.Thread(target=_warmup, daemon=True).start()
    threading.Thread(target=_poller, args=(args.interval,), daemon=True).start()

    def _usb_get_usage():
        return json.dumps(rollup()).encode()

    def _usb_sync_refresh():
        threading.Thread(
            target=_refresh_selected,
            kwargs={
                "sources": list(sources_config.SOURCE_IDS),
                "force": True,
            },
            daemon=True,
        ).start()

    threading.Thread(
        target=usb_bridge.run,
        kwargs={
            "get_usage": _usb_get_usage,
            "on_sync_refresh": _usb_sync_refresh,
        },
        daemon=True,
    ).start()

    srv = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    print(f"Serving usage JSON on http://0.0.0.0:{args.port}/usage", flush=True)
    print(f"Health check at http://127.0.0.1:{args.port}/health", flush=True)
    print("USB CDC fallback: HR protocol on /dev/cu.usbmodem* (best-effort)",
          flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbye", flush=True)


if __name__ == "__main__":
    main()
