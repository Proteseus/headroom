"""Local listening servers for the desk gadget.

Runs `lsof` for TCP LISTEN sockets, filters to likely dev processes
(node/python/… + well-known ports), resolves each process cwd, and returns
a short list labeled by project directory when possible.

Stdlib only. Failures degrade to {ok: false}.
"""

from __future__ import annotations

import os
import re
import signal
import socket
import subprocess
import time

import cache_util

CACHE_TTL_S = 15
FAIL_TTL_S = 10
KEEP = 8
NAME_MAX = 16

# Port → fallback label when cwd can't be resolved (infra / tools).
KNOWN_PORTS = {
    3000: "Next",
    3001: "Next",
    4173: "Vite",
    5001: "Flask",
    5173: "Vite",
    5432: "Postgres",
    5433: "Postgres",
    6379: "Redis",
    8000: "API",
    8080: "HTTP",
    8888: "Jupyter",
    11434: "Ollama",
    1313: "Hugo",
    4321: "Astro",
    24678: "Vite HMR",
}

# Commands we care about even on unknown ports (prefix match, casefold).
INTERESTING_CMDS = (
    "node", "python", "ruby", "php", "java", "deno", "bun",
    "nginx", "caddy", "httpd", "postgres", "redis", "mongod",
    "docker", "com.docke", "orbstack", "uvicorn", "gunicorn",
    "next-serv", "vite", "wrangler", "cloudflared", "ngrok",
)

# Noise: OS / browser / IDE internals.
SKIP_CMDS = (
    "rapportd", "controlce", "controlcenter", "ipnextens",
    "google", "chrome", "raycast", "github", "cursorsan",
    "spotify", "zoom", "slack", "figma", "adobe",
)

SELF_PORT = 8737
HOME = os.path.expanduser("~")

_NAME_PORT = re.compile(r":(\d+)\s*\(LISTEN\)")

_cache = {"t": 0.0, "data": None}


def _hostname():
    try:
        return socket.gethostname().split(".")[0] or "localhost"
    except OSError:
        return "localhost"


def _interesting_cmd(cmd):
    c = (cmd or "").casefold()
    if not c:
        return False
    for skip in SKIP_CMDS:
        if c.startswith(skip):
            return False
    for pref in INTERESTING_CMDS:
        if c.startswith(pref):
            return True
    return False


def _truncate(s, n=NAME_MAX):
    s = (s or "").strip()
    if len(s) <= n:
        return s
    return s[: n - 1] + "…"


def _dir_label(cwd):
    """Basename of the process working directory, if it looks like a project."""
    if not cwd:
        return None
    path = os.path.abspath(cwd.rstrip("/"))
    if path in ("/", HOME):
        return None
    base = os.path.basename(path)
    if not base or base in (".", "..", "tmp", "Temp", "var", "private"):
        return None
    return _truncate(base)


def _fallback_label(port, cmd):
    if port in KNOWN_PORTS:
        return KNOWN_PORTS[port]
    return _truncate((cmd or "proc").strip() or "proc")


def _probe(port):
    """Best-effort local TCP reachability and connect latency."""
    started = time.perf_counter()
    for host in ("127.0.0.1", "::1"):
        try:
            with socket.create_connection((host, int(port)), timeout=0.2):
                elapsed = (time.perf_counter() - started) * 1000
                return True, max(1, int(round(elapsed)))
        except OSError:
            continue
    return False, None


def _parse_lsof(raw):
    """Return dict port -> {port, pid, cmd, bind} (last wins)."""
    by_port = {}
    for line in raw.splitlines()[1:]:  # skip header
        parts = line.split()
        if len(parts) < 9:
            continue
        cmd = parts[0]
        try:
            pid = int(parts[1])
        except ValueError:
            continue
        name = " ".join(parts[8:])
        m = _NAME_PORT.search(name)
        if not m:
            continue
        port = int(m.group(1))
        bind = "local"
        if "*:" in name:
            bind = "*"
        elif "127.0.0.1:" in name or "[::1]:" in name:
            bind = "loop"
        by_port[port] = {"port": port, "pid": pid, "cmd": cmd, "bind": bind}
    return by_port


def _lsof_listen():
    try:
        return subprocess.check_output(
            ["lsof", "-nP", "-iTCP", "-sTCP:LISTEN"],
            stderr=subprocess.DEVNULL,
            timeout=8,
            text=True,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired,
            FileNotFoundError, OSError):
        return ""


def _cwds_for_pids(pids):
    """Map pid -> absolute cwd via a single lsof -d cwd call."""
    out = {}
    ids = sorted({int(p) for p in pids if p})
    if not ids:
        return out
    # lsof accepts comma-separated -p lists.
    try:
        raw = subprocess.check_output(
            ["lsof", "-a", "-d", "cwd", "-p", ",".join(str(p) for p in ids)],
            stderr=subprocess.DEVNULL,
            timeout=8,
            text=True,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired,
            FileNotFoundError, OSError):
        return out

    cur_pid = None
    for line in raw.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 9:
            continue
        try:
            cur_pid = int(parts[1])
        except ValueError:
            continue
        if parts[3] != "cwd":
            continue
        # NAME is the last field(s); path may contain spaces (rare).
        path = parts[-1] if parts[-1].startswith("/") else " ".join(parts[8:])
        if path.startswith("/"):
            out[cur_pid] = path
    return out


def _pid_uid(pid):
    """Return the process owner uid, or None if the process disappeared."""
    try:
        raw = subprocess.check_output(
            ["ps", "-o", "uid=", "-p", str(int(pid))],
            stderr=subprocess.DEVNULL,
            timeout=3,
            text=True,
        ).strip()
        return int(raw) if raw else None
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired,
            FileNotFoundError, OSError, TypeError, ValueError):
        return None


def stop_server(pid, port):
    """SIGTERM an exact, currently-listed local dev server.

    The live listener table is checked again to prevent a stale UI row from
    terminating a reused PID or a process that moved to another port.
    """
    try:
        pid = int(pid)
        port = int(port)
    except (TypeError, ValueError):
        return {"ok": False, "error": "invalid pid or port"}

    if pid <= 1 or pid == os.getpid() or port == SELF_PORT:
        return {"ok": False, "error": "protected process"}

    live = _parse_lsof(_lsof_listen()).get(port)
    if not live or live.get("pid") != pid:
        return {"ok": False, "error": "server is no longer listening there"}

    cmd = live.get("cmd")
    if port not in KNOWN_PORTS and not _interesting_cmd(cmd):
        return {"ok": False, "error": "process is not a listed dev server"}

    if _pid_uid(pid) != os.getuid():
        return {"ok": False, "error": "process belongs to another user"}

    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return {"ok": False, "error": "server already stopped"}
    except PermissionError:
        return {"ok": False, "error": "permission denied"}
    except OSError as exc:
        return {"ok": False, "error": str(exc)}

    _cache.update(t=0.0, data=None)
    return {"ok": True, "pid": pid, "port": port}


def fetch_servers(force=False):
    """Return {ok, host, servers:[{name, port, cmd, cwd, bind}], error}."""
    now = time.time()
    if not force and _cache["data"] is not None:
        ttl = CACHE_TTL_S if _cache["data"].get("ok") else FAIL_TTL_S
        if now - _cache["t"] < ttl:
            return _cache["data"]

    host = _hostname()
    empty = {"ok": False, "host": host, "servers": [], "error": None}
    try:
        raw = _lsof_listen()
        if not raw.strip():
            out = {
                "ok": True, "host": host, "servers": [],
                "error": None, "stale": False,
            }
            _cache.update(t=now, data=out, err=None)
            return out

        by_port = _parse_lsof(raw)
        candidates = []
        for port, info in by_port.items():
            cmd = info["cmd"]
            known = port in KNOWN_PORTS
            if not known and not _interesting_cmd(cmd):
                continue
            if port == SELF_PORT:
                continue
            candidates.append(info)

        cwds = _cwds_for_pids(c["pid"] for c in candidates)

        rows = []
        for info in candidates:
            port = info["port"]
            cmd = info["cmd"]
            cwd = cwds.get(info["pid"])
            name = _dir_label(cwd) or _fallback_label(port, cmd)
            reachable, latency_ms = _probe(port)
            rows.append({
                "name": name,
                "port": port,
                "pid": info["pid"],
                "cmd": cmd,
                "cwd": cwd,
                "bind": info["bind"],
                "reachable": reachable,
                "latency_ms": latency_ms,
            })

        # Prefer rows with a real project dir, then lower ports.
        rows.sort(key=lambda r: (
            0 if r.get("cwd") and _dir_label(r["cwd"]) else 1,
            r["port"],
        ))
        out = {
            "ok": True,
            "host": host,
            "servers": rows[:KEEP],
            "error": None,
            "stale": False,
        }
        _cache.update(t=now, data=out, err=None)
        return out
    except Exception as exc:
        return cache_util.keep_stale(_cache, now, str(exc), empty)
