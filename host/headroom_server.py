#!/usr/bin/env python3
"""headroom — Claude + Codex + Cursor (+ Vercel + Git + Local) desk host.

Parses ~/.claude/projects/**/*.jsonl (the same usage logs `ccusage` reads),
aggregates token counts and cost into rolling time windows, and serves a flat
JSON document at GET http://<mac>:8737/usage for a Waveshare ESP32-S3 to poll.

Also polls Anthropic OAuth, OpenAI Codex (wham/usage), and Cursor
(GetCurrentPeriodUsage) quotas, Vercel team deployments, local git activity,
and listening local servers so the desk gadget can flip pages.

Zero dependencies — Python 3 standard library only. Incremental: each file's
byte offset is remembered so a poll only reads newly-appended lines instead of
rescanning every file.

Run:  python3 headroom_server.py [--port 8737] [--interval 15]
"""

import argparse
import ipaddress
import json
import os
import threading
import time
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
import local_servers

LOG_ROOT = os.path.expanduser("~/.claude/projects")
RETENTION_S = 7 * 24 * 3600  # keep events long enough for the weekly window
LOCAL_TZ = ZoneInfo("Europe/Berlin")  # CET/CEST
QUOTA_POLL_S = 60  # usage endpoints are rate-limited; don't hammer them

_lock = threading.Lock()
_offsets = {}   # filepath -> bytes already consumed
_events = []    # list of dicts: {t, model, in, out, cr, w5, w1, cost}
_quota = {"ok": False, "plan": None, "session": None, "week": None}
_codex = {"ok": False, "plan": None, "session": None, "week": None}
_cursor = {"ok": False, "plan": None, "auto": None, "api": None}
_vercel = {"ok": False, "team": None, "deployments": []}
_git = {"ok": False, "commits": []}
_local = {"ok": False, "host": None, "servers": []}


def _unix_seconds(value):
    try:
        value = float(value)
        return value / 1000.0 if value > 1e12 else value
    except (TypeError, ValueError):
        return 0.0


def _build_activity(vercel, git):
    """Merge Vercel builds and local commits into one newest-first timeline."""
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
    }


def _flatten_cursor(cursor):
    """Flat Total/Auto/API fields for the ESP32 and menu-bar Cursor views."""
    total_q = cursor.get("total") or {}
    auto_q = cursor.get("auto") or {}
    api_q = cursor.get("api") or {}
    pace = cursor.get("pace") or {}
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
        "on_demand_label": on_demand.get("label"),
        "on_demand_remaining_usd": on_demand.get("remaining_usd"),
        "on_demand_limit_usd": on_demand.get("limit_usd"),
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
        local = dict(_local)

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

    # Flatten Claude fields at the top level (back-compat with older firmware).
    session_q = quota.get("session") or {}
    week_q = quota.get("week") or {}
    session_resets = session_q.get("resets_in_s")
    week_resets = week_q.get("resets_in_s")
    return {
        "updated": datetime.now(LOCAL_TZ).strftime("%Y-%m-%dT%H:%M:%S%z"),
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
        "quota": quota,
        "codex": _flatten_codex(codex),
        "cursor": _flatten_cursor(cursor),
        "vercel": {
            "ok": bool(vercel.get("ok")),
            "team": vercel.get("team"),
            "error": vercel.get("error"),
            "deployments": vercel.get("deployments") or [],
        },
        "git": {
            "ok": bool(git.get("ok")),
            "error": git.get("error"),
            "commits": git.get("commits") or [],
        },
        "activity": _build_activity(vercel, git),
        "local": {
            "ok": bool(local.get("ok")),
            "host": local.get("host"),
            "error": local.get("error"),
            "servers": local.get("servers") or [],
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

    def do_GET(self):
        if self.path.rstrip("/") in ("", "/usage"):
            self._send_json(200, rollup())
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path.rstrip("/") != "/local/stop":
            self.send_error(404)
            return
        if not self._is_loopback():
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

        result = local_servers.stop_server(
            payload.get("pid"), payload.get("port"))
        if result.get("ok"):
            time.sleep(0.2)
            _refresh_local(force=True)
            self._send_json(200, result)
        else:
            self._send_json(409, result)

    def log_message(self, *args):
        pass  # quiet; this is a desk gadget, not a web server


def _refresh_quotas(force=False):
    """Pull Claude + Codex + Cursor quotas, Vercel, git, local servers."""
    global _quota, _codex, _cursor, _vercel, _git, _local
    try:
        q = oauth_usage.fetch_quota(force=force)
        with _lock:
            _quota = q
        if q.get("ok"):
            s = q.get("session") or {}
            w = q.get("week") or {}
            print(f"claude ok  plan={q.get('plan')}  "
                  f"session={s.get('pct')}%  week={w.get('pct')}%")
        else:
            print("claude miss:", q.get("error"))
    except Exception as exc:
        print("claude error:", exc)

    try:
        c = codex_usage.fetch_quota(force=force)
        with _lock:
            _codex = c
        if c.get("ok"):
            s = c.get("session") or {}
            w = c.get("week") or {}
            pace = (c.get("pace") or {}).get("label") or "-"
            credits = (c.get("reset_credits") or {}).get("available")
            print(f"codex ok   plan={c.get('plan')}  "
                  f"session={s.get('pct')}%  week={w.get('pct')}%  "
                  f"pace={pace}  credits={credits}")
        else:
            print("codex miss:", c.get("error"))
    except Exception as exc:
        print("codex error:", exc)

    try:
        cu = cursor_usage.fetch_quota(force=force)
        with _lock:
            _cursor = cu
        if cu.get("ok"):
            a = cu.get("auto") or {}
            p = cu.get("api") or {}
            print(f"cursor ok  plan={cu.get('plan')}  "
                  f"auto={a.get('pct')}%  api={p.get('pct')}%  "
                  f"resets={cu.get('resets_in_s')}")
        else:
            print("cursor miss:", cu.get("error"))
    except Exception as exc:
        print("cursor error:", exc)

    try:
        v = vercel_builds.fetch_deployments(force=force)
        with _lock:
            _vercel = v
        if v.get("ok"):
            n = len(v.get("deployments") or [])
            print(f"vercel ok  team={v.get('team')}  deploys={n}")
        else:
            print("vercel miss:", v.get("error"))
    except Exception as exc:
        print("vercel error:", exc)

    try:
        g = git_activity.fetch_commits(force=force)
        with _lock:
            _git = g
        if g.get("ok"):
            n = len(g.get("commits") or [])
            print(f"git ok     commits={n}")
        else:
            print("git miss:", g.get("error"))
    except Exception as exc:
        print("git error:", exc)

    try:
        loc = local_servers.fetch_servers(force=force)
        with _lock:
            _local = loc
        if loc.get("ok"):
            n = len(loc.get("servers") or [])
            print(f"local ok   host={loc.get('host')}  servers={n}")
        else:
            print("local miss:", loc.get("error"))
    except Exception as exc:
        print("local error:", exc)


def _refresh_local(force=False):
    global _local
    try:
        loc = local_servers.fetch_servers(force=force)
        with _lock:
            _local = loc
    except Exception as exc:
        print("local error:", exc)


def _poller(interval):
    last_quota = 0.0
    last_local = 0.0
    while True:
        try:
            scan()
        except Exception as exc:  # keep the daemon alive across odd records
            print("scan error:", exc)
        now = time.time()
        if now - last_local >= local_servers.CACHE_TTL_S:
            last_local = now
            _refresh_local()
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

    print(f"Bootstrapping from {LOG_ROOT} ...")
    t0 = time.time()
    scan()
    with _lock:
        n = len(_events)
    print(f"  {n} events in the last 7 days ({time.time()-t0:.1f}s)")

    print("Refreshing Claude + Codex + Cursor quotas, Vercel, git, local ...")
    threading.Thread(target=_poller, args=(args.interval,), daemon=True).start()

    srv = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    print(f"Serving usage JSON on http://0.0.0.0:{args.port}/usage")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
