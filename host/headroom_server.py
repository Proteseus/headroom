#!/usr/bin/env python3
"""headroom — Claude + Codex + Cursor (+ Vercel + Git + GitHub + Local) desk host.

Parses ~/.claude/projects/**/*.jsonl (the same usage logs `ccusage` reads),
aggregates token counts and cost into rolling time windows, and serves a flat
JSON document at GET http://<mac>:8737/usage for a Waveshare ESP32-S3 to poll
(Wi-Fi), with a best-effort USB CDC fallback (HR framed protocol) in-process.

Also polls Anthropic OAuth, OpenAI Codex (wham/usage), and Cursor
(GetCurrentPeriodUsage) quotas, Vercel team deployments, local git activity,
GitHub Actions failures, and listening local servers so the desk gadget can
flip pages. Every watched service is one row in sources_config.SOURCES.

The served document is rebuilt once per poll tick and cached as bytes — a GET
is a memcpy, not a re-aggregation, because three clients poll this thing.
`?view=device` returns the trimmed projection the ESP32 reads (see
device_view.py). Non-loopback callers must present the shared token (auth.py).

Zero dependencies — Python 3 standard library only. Incremental: each file's
byte offset is remembered so a poll only reads newly-appended lines instead of
rescanning every file, and files untouched since the retention cutoff are never
opened at all.

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
from datetime import datetime
from zoneinfo import ZoneInfo
from glob import glob
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import app_config
import auth
import burndown
import claude_history
import daily_burn
import device_view
import local_servers
import oauth_usage
import quota_samples
import sources_config
import usb_bridge

LOG_ROOT = os.path.expanduser("~/.claude/projects")
RETENTION_S = 7 * 24 * 3600  # keep events long enough for the weekly window
BOOT_T0 = time.time()
LOG_ROTATE_S = 15 * 60


def _local_tz():
    try:
        return ZoneInfo(app_config.timezone_name())
    except Exception:
        return ZoneInfo("UTC")


_lock = threading.Lock()
_offsets = {}   # filepath -> bytes already consumed
# (minute_epoch, model) -> [input, output, cache_read, write_5m, write_1h, cost].
# Bucketing by minute bounds memory by active minutes rather than by message
# count, and makes the rollup O(active minutes) instead of O(every message).
_buckets = {}
_state = sources_config.blank_state()          # source id -> latest payload
_source_times = {sid: 0.0 for sid in sources_config.SOURCE_IDS}

# Pre-rendered response bodies, rebuilt at the end of each poll tick.
_cache_lock = threading.Lock()
_cache = {"doc": None, "usage": b"", "device": b"", "built": 0.0}


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


def _event_from(rec, cutoff):
    """Turn one assistant log record into a bucket key + totals, or None.

    Parsing and pricing live in claude_history so the live rollup and the
    long-range backfill can't drift apart; this only adds minute bucketing and
    the retention cutoff.
    """
    parsed = claude_history.usage_from_record(rec)
    if parsed is None:
        return None
    t, model, inp, out, cr, w5, w1, cost = parsed
    if t < cutoff:
        return None
    return (int(t) // 60, model, inp, out, cr, w5, w1, cost)


def _read_file(path, from_offset, cutoff):
    """Read a jsonl file from a byte offset; return (events, new_offset)."""
    events = []
    try:
        with open(path, "rb") as fh:
            fh.seek(from_offset)
            data = fh.read()
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
        ev = _event_from(rec, cutoff)
        if ev:
            events.append(ev)
    return events, new_offset


def scan():
    """Incrementally ingest new log lines and prune stale buckets."""
    now = time.time()
    cutoff = now - RETENTION_S
    fresh = []
    seen = set()

    for path in glob(os.path.join(LOG_ROOT, "**", "*.jsonl"), recursive=True):
        seen.add(path)
        try:
            stat = os.stat(path)
        except OSError:
            continue
        off = _offsets.get(path, 0)
        # A file untouched since the cutoff can only hold events we would prune
        # anyway. Mark it fully consumed and never open it again — this is what
        # keeps a cold start from parsing hundreds of MB of archived sessions.
        if stat.st_mtime < cutoff:
            _offsets[path] = stat.st_size
            continue
        if stat.st_size < off:
            off = 0          # truncated or rotated — start over
        elif stat.st_size == off:
            continue         # nothing appended since last tick
        evs, new_off = _read_file(path, off, cutoff)
        _offsets[path] = new_off
        fresh.extend(evs)

    # Forget files that disappeared, so the offset map tracks the log dir
    # rather than growing for the life of the process.
    if len(_offsets) > len(seen):
        for gone in [p for p in _offsets if p not in seen]:
            del _offsets[gone]

    cutoff_minute = int(cutoff) // 60
    with _lock:
        for minute, model, inp, out, cr, w5, w1, cost in fresh:
            bucket = _buckets.get((minute, model))
            if bucket is None:
                _buckets[(minute, model)] = [inp, out, cr, w5, w1, cost]
                continue
            bucket[0] += inp
            bucket[1] += out
            bucket[2] += cr
            bucket[3] += w5
            bucket[4] += w1
            bucket[5] += cost
        stale = [key for key in _buckets if key[0] < cutoff_minute]
        for key in stale:
            del _buckets[key]


def _blank():
    return {"input": 0, "output": 0, "cache_read": 0,
            "cache_write": 0, "total": 0, "cost_usd": 0.0}


def _accumulate(target, bucket):
    inp, out, cr, w5, w1, cost = bucket
    target["input"] += inp
    target["output"] += out
    target["cache_read"] += cr
    target["cache_write"] += w5 + w1
    target["total"] += inp + out + cr + w5 + w1
    target["cost_usd"] += cost


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
        "session_resets_in": oauth_usage.fmt_resets(session_resets),
        "week_pct": week_q.get("pct"),
        "week_pace_pct": oauth_usage.pace_pct(week_resets, week_window),
        "week_resets_in_s": week_resets,
        "week_resets_in": oauth_usage.fmt_resets(week_resets),
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


def _cost_since(start_ts):
    """USD of Claude work recorded since `start_ts`, from the live buckets."""
    with _lock:
        buckets = [(minute, bucket[5]) for (minute, _model), bucket
                   in _buckets.items()]
    return sum(cost for minute, cost in buckets if minute * 60 >= start_ts)


# The ratio needs enough of a window behind it to mean anything.
PRIOR_MIN_ELAPSED_S = 2 * 3600
PRIOR_MIN_PCT = 1.0
PRIOR_MIN_COST_USD = 1.0


def _burn_priors(state, history, now):
    """Per-provider %/day burn estimates for windows too fresh to fit.

    The quota APIs only ever report *now*, so no amount of backfill can
    reconstruct a percent history. What the session logs do give is cost, and
    the current window supplies the missing conversion: it has both a percent
    used and the work that produced it. That ratio against the historical daily
    average is a defensible %/day estimate.

    Cost rather than token count, deliberately: a cache read is a tenth of an
    input token and output is five times one, so raw totals wildly understate
    the price of the tokens that actually move the meter. `pricing` already
    carries those weights.

    Both sides must cover the *same* window. Anthropic's weekly window rolls
    from its own start, which is rarely 7 calendar days ago, so the denominator
    is summed from that start rather than from a rolling week.

    Claude only — Codex and Cursor keep no local log. Anything resting on this
    is marked `estimated` by burndown.
    """
    if not history:
        return {}
    week = ((state or {}).get("claude") or {}).get("week") or {}
    try:
        used_pct = float(week.get("pct"))
        resets_in_s = float(week.get("resets_in_s"))
    except (TypeError, ValueError):
        return {}

    window_s = week.get("window_s") or oauth_usage.WEEK_WINDOW_S
    elapsed = window_s - max(0.0, min(resets_in_s, window_s))
    avg_cost_per_day = history.get("avg_cost_per_active_day") or 0
    if elapsed < PRIOR_MIN_ELAPSED_S or used_pct < PRIOR_MIN_PCT:
        return {}
    if avg_cost_per_day <= 0:
        return {}

    cost_in_window = _cost_since(now - elapsed)
    if cost_in_window < PRIOR_MIN_COST_USD:
        return {}

    estimate = (used_pct / cost_in_window) * float(avg_cost_per_day)
    # A prior that predicts blowing the window many times over is a broken
    # ratio, not a real forecast.
    if not (0 < estimate < 200):
        return {}
    return {"claude": estimate}


def _compute_doc():
    """Build the full /usage document from current state. Pure-ish; no I/O."""
    now = time.time()
    local_midnight = datetime.now().astimezone().replace(
        hour=0, minute=0, second=0, microsecond=0).timestamp()

    today, week, session_5h, last_hour = _blank(), _blank(), _blank(), _blank()
    by_model = {}

    with _lock:
        buckets = {key: list(value) for key, value in _buckets.items()}
        state = {sid: dict(payload) for sid, payload in _state.items()}

    # Bucket timestamps are minute-aligned, so window edges are accurate to
    # the minute — well inside what a desk gadget can show.
    for (minute, model), bucket in buckets.items():
        t = minute * 60
        if t >= now - 7 * 24 * 3600:
            _accumulate(week, bucket)
        if t >= local_midnight:
            _accumulate(today, bucket)
            _accumulate(by_model.setdefault(model, _blank()), bucket)
        if t >= now - 5 * 3600:
            _accumulate(session_5h, bucket)
        if t >= now - 3600:
            _accumulate(last_hour, bucket)

    for bucket in (today, week, session_5h, last_hour, *by_model.values()):
        bucket["cost_usd"] = round(bucket["cost_usd"], 4)

    quota = state["claude"]
    vercel = state["vercel"]
    git = state["git"]
    github = state["github"]
    local = state["local"]
    supabase = state["supabase"]

    local_tz = _local_tz()
    history = claude_history.summary(days=30)
    burndowns = burndown.compute_all(
        state, now=now, tz=local_tz,
        priors=_burn_priors(state, history, now),
    )
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
        # Per-pool burndown: ideal decay, actual curve, and time-to-exhaustion.
        # `burndown_primary` is the pool most worth showing — what the menu-bar
        # icon and the board's headline follow.
        "burndown": burndowns,
        "burndown_primary": burndown.primary(burndowns),
        # Months of real Claude usage, backfilled from the session logs. Token
        # history, not quota-percent history — see claude_history.
        "history": history,
        "quota": quota,
        "codex": _flatten_codex(state["codex"]),
        "cursor": _flatten_cursor(state["cursor"]),
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
        "activity": _build_activity(vercel, git, supabase, github),
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
        "sources": _sources_payload(state),
    }
    doc["attention"] = _build_attention(doc)
    return doc


def publish():
    """Rebuild the cached document and its encoded bodies. Returns the doc."""
    doc = _compute_doc()
    usage = json.dumps(doc).encode()
    device = json.dumps(
        device_view.build(doc), separators=(",", ":")).encode()
    with _cache_lock:
        _cache.update(doc=doc, usage=usage, device=device, built=time.time())
    return doc


def rollup():
    """Current /usage document, building one if the cache is cold."""
    with _cache_lock:
        doc = _cache["doc"]
    return doc if doc is not None else publish()


def _bodies():
    """(usage_bytes, device_bytes) for the current document."""
    with _cache_lock:
        if _cache["doc"] is not None:
            return _cache["usage"], _cache["device"]
    publish()
    with _cache_lock:
        return _cache["usage"], _cache["device"]


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


def _sources_payload(state):
    enabled = sources_config.enabled_map()
    now = time.time()
    with _lock:
        times = dict(_source_times)
    rows = []
    for source in sources_config.SOURCES:
        payload = state.get(source.id) or {}
        age = times.get(source.id) or 0.0
        rows.append({
            "id": source.id,
            "title": source.title,
            "hint": source.hint,
            "enabled": bool(enabled.get(source.id, True)),
            "ok": bool(payload.get("ok")),
            "stale": bool(payload.get("stale")),
            "configured": payload.get("configured"),
            "error": payload.get("error"),
            "detail": sources_config.detail_for(source.id, payload),
            "age_s": (int(max(0, now - age)) if age > 0 else None),
        })
    return rows


def _health_payload():
    doc = rollup()
    with _cache_lock:
        built = _cache["built"] or 0.0
    by_id = {row["id"]: row for row in (doc.get("sources") or [])}
    return {
        "ok": True,
        "uptime_s": int(max(0, time.time() - BOOT_T0)),
        "updated": doc.get("updated"),
        "built_age_s": int(max(0, time.time() - built)),
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
        self._send_bytes(status, json.dumps(payload).encode())

    def _send_bytes(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _client_ip(self):
        try:
            address = ipaddress.ip_address(self.client_address[0])
        except ValueError:
            return None
        mapped = getattr(address, "ipv4_mapped", None)
        return mapped or address

    def _is_loopback(self):
        address = self._client_ip()
        return bool(address and address.is_loopback)

    def _is_private(self):
        """Loopback or RFC1918 — desk gadgets on the LAN may force a sync."""
        address = self._client_ip()
        return bool(address and (address.is_loopback or address.is_private))

    def _allowed(self):
        """Loopback is trusted; everything off-box needs the shared token."""
        if self._is_loopback():
            return True
        return auth.authorized(self.headers)

    def do_GET(self):
        split = urllib.parse.urlsplit(self.path)
        path = split.path.rstrip("/")
        if path not in ("", "/usage", "/health"):
            self.send_error(404)
            return
        if not self._allowed():
            self._send_json(401, {"ok": False, "error": "token required"})
            return
        if path == "/health":
            self._send_json(200, _health_payload())
            return
        view = urllib.parse.parse_qs(split.query).get("view", [""])[0]
        usage, device = _bodies()
        self._send_bytes(200, device if view == "device" else usage)

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
        if not self._allowed():
            self._send_json(401, {"ok": False, "error": "token required"})
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
            _refresh_async([sid for sid, on in result.items() if on])
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
                if sid in sources_config.BY_ID
            ]
            _refresh_async(wanted)
            self._send_json(202, {"ok": True, "sources": wanted})
            return

        result = local_servers.stop_server(
            payload.get("pid"), payload.get("port"))
        if result.get("ok"):
            time.sleep(0.2)
            _refresh_one("local", force=True)
            publish()
            self._send_json(200, result)
        else:
            self._send_json(409, result)

    def log_message(self, *args):
        pass  # quiet; this is a desk gadget, not a web server


def _refresh_one(source_id, force=False):
    """Fetch one source and store it. Never raises."""
    source = sources_config.get(source_id)
    if source is None:
        return
    try:
        payload = source.fetch(force=force)
    except Exception as exc:
        print(f"{source_id} error:", exc)
        return
    with _lock:
        _state[source_id] = payload
        _source_times[source_id] = time.time()
    if payload.get("ok"):
        stale = "  stale" if payload.get("stale") else ""
        print(f"{source_id:9s} ok  {source.summary(payload)}{stale}")
    else:
        print(f"{source_id:9s} miss:", payload.get("error"))


def _observe_burn():
    try:
        with _lock:
            quota = dict(_state["claude"])
            codex = dict(_state["codex"])
            cursor = dict(_state["cursor"])
        today_burn = daily_burn.observe(quota, codex, cursor, tz=_local_tz())
        print(
            "burn today "
            f"claude={today_burn.get('claude')}%  "
            f"codex={today_burn.get('codex')}%  "
            f"cursor={today_burn.get('cursor')}%"
        )
    except Exception as exc:
        print("daily_burn error:", exc)


def _sample_quotas():
    """Append raw (t, pct) samples — the series behind burndown + forecast.

    Separate from _observe_burn: that accumulates %-points per calendar day,
    this keeps the intra-window shape those daily totals can't reconstruct.
    """
    try:
        with _lock:
            state = {sid: dict(_state[sid])
                     for sid in sources_config.BURN_SOURCE_IDS}
        rows = quota_samples.record(state)
        if rows:
            print("sampled " + "  ".join(
                f"{row['provider']}.{row['pool']}={row['pct']}%"
                for row in rows))
    except Exception as exc:
        print("quota_samples error:", exc)


def _refresh_selected(sources, force=False):
    """Refresh the given sources in parallel (enabled filter still applies)."""
    enabled = sources_config.enabled_map()
    wanted = [
        sid for sid in sources
        if sid in sources_config.BY_ID and enabled.get(sid, True)
    ]
    if not wanted:
        return
    with concurrent.futures.ThreadPoolExecutor(
            max_workers=min(8, len(wanted))) as pool:
        list(pool.map(
            lambda sid: _refresh_one(sid, force=force),
            wanted,
        ))
    if any(sid in sources_config.BURN_SOURCE_IDS for sid in wanted):
        _observe_burn()
        _sample_quotas()
    publish()


def _refresh_async(sources, force=True):
    threading.Thread(
        target=_refresh_selected,
        kwargs={"sources": list(sources), "force": force},
        daemon=True,
    ).start()


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
    """One loop, driven by each source's own poll_s from the registry."""
    # Warmup already forced a full pass, so start the clocks now rather than
    # refetching everything on the first tick.
    started = time.time()
    last_run = {sid: started for sid in sources_config.SOURCE_IDS}
    last_rotate = started
    while True:
        try:
            scan()
        except Exception as exc:  # keep the daemon alive across odd records
            print("scan error:", exc)

        now = time.time()
        due = [
            source.id for source in sources_config.SOURCES
            if now - last_run[source.id] >= source.poll_s
        ]
        for sid in due:
            last_run[sid] = now
        if due:
            _refresh_selected(due)
        else:
            publish()   # keep `updated` and pace marks moving

        if now - last_rotate >= LOG_ROTATE_S:
            last_rotate = now
            _rotate_logs()
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
        n = len(_buckets)
    print(f"  {n} active minutes in the last 7 days "
          f"({time.time()-t0:.1f}s)", flush=True)

    def _warmup():
        print("Refreshing enabled sources ...", flush=True)
        try:
            _refresh_selected(sources_config.SOURCE_IDS, force=True)
        except Exception as exc:
            print("warmup error:", exc, flush=True)

    def _backfill_history():
        """One resumable pass over every session log, off the startup path.

        First run against a large ~/.claude tree takes a while, so it never
        blocks serving; after that unchanged files cost a stat each.
        """
        try:
            result = claude_history.backfill(
                tz=_local_tz(),
                log=lambda line: print(line, flush=True),
            )
            if result.get("error"):
                print("history backfill error:", result["error"], flush=True)
                return
            summary = claude_history.summary(days=30)
            if summary:
                print(
                    f"history: {result['scanned']} files in "
                    f"{result['elapsed_s']:.1f}s — "
                    f"{summary['active_days']} active days since "
                    f"{summary['first_day']}, "
                    f"{summary['total_tokens'] / 1e6:.1f}M tokens, "
                    f"${summary['total_cost_usd']:.2f}",
                    flush=True,
                )
            else:
                print(f"history: no usage found under {claude_history.LOG_ROOT}",
                      flush=True)
            publish()
        except Exception as exc:
            print("history backfill error:", exc, flush=True)

    publish()
    threading.Thread(target=_backfill_history, daemon=True).start()
    threading.Thread(target=_warmup, daemon=True).start()
    threading.Thread(target=_poller, args=(args.interval,), daemon=True).start()

    def _usb_get_usage():
        # The cable is slow: hand the board its trimmed view, not the full doc.
        return _bodies()[1]

    def _usb_sync_refresh():
        _refresh_async(sources_config.SOURCE_IDS)

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
    print(f"  device view:  http://0.0.0.0:{args.port}/usage?view=device",
          flush=True)
    print(f"  health check: http://127.0.0.1:{args.port}/health", flush=True)
    if auth.required():
        print(f"LAN clients need this token (also in {auth.TOKEN_PATH}):",
              flush=True)
        print(f"  {auth.token()}", flush=True)
        print("  put it in firmware/src/config.h as HOST_TOKEN", flush=True)
    else:
        print("require_auth is off — /usage is open to the whole network",
              flush=True)
    print("USB CDC fallback: HR protocol on /dev/cu.usbmodem* (best-effort)",
          flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbye", flush=True)


if __name__ == "__main__":
    main()
