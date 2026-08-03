"""Active local Xcode / Swift builds for the desk gadget.

Surfaces CLI `xcodebuild` / `swift build` (agents, scripts) and IDE builds
that are actually compiling — compiler workers under XCBuildService,
SWBBuildService, or Xcode — labeled by scheme or DerivedData project.

Idle build services with no compiler children are ignored. Failures degrade
to {ok: false}. Stdlib only.
"""

from __future__ import annotations

import os
import plistlib
import re
import socket
import subprocess
import time

import cache_util

CACHE_TTL_S = 10
FAIL_TTL_S = 10
KEEP = 8
NAME_MAX = 16

ACTIONS = ("build", "test", "archive", "analyze", "clean", "install")

# Parent of an active IDE compile. Presence alone is not enough — Xcode keeps
# these warm while idle.
BUILD_SERVICES = ("XCBuildService", "SWBBuildService", "Xcode")

# Live work units. A build service with one of these as a descendant is busy.
COMPILER_CMDS = (
    "swift-frontend", "swift-driver", "swiftc",
    "clang", "clang++", "ld", "libtool",
    "ibtool", "actool", "metal", "llc",
)

DERIVED_RE = re.compile(
    r"/DerivedData/([^/]+)-[A-Za-z0-9]+(?:/|$)")

_cache = {"t": 0.0, "data": None}
_derived_cache = {}


def invalidate():
    _cache.update(t=0.0, data=None)
    _derived_cache.clear()


def _hostname():
    try:
        return socket.gethostname().split(".")[0] or "localhost"
    except OSError:
        return "localhost"


def _truncate(s, n=NAME_MAX):
    s = (s or "").strip()
    if len(s) <= n:
        return s
    return s[: n - 1] + "…"


def _basename_cmd(args):
    """Executable basename from a full `ps` args line."""
    if not args:
        return ""
    first = args.split(None, 1)[0]
    return os.path.basename(first.rstrip(":"))


def _parse_etime(raw):
    """`ps` etime → seconds. Accepts [[dd-]hh:]mm:ss and bare seconds."""
    s = (raw or "").strip()
    if not s:
        return 0
    days = 0
    if "-" in s:
        day_part, s = s.split("-", 1)
        try:
            days = int(day_part)
        except ValueError:
            return 0
    parts = s.split(":")
    try:
        nums = [int(p) for p in parts]
    except ValueError:
        return 0
    if len(nums) == 1:
        return days * 86400 + nums[0]
    if len(nums) == 2:
        return days * 86400 + nums[0] * 60 + nums[1]
    if len(nums) == 3:
        return days * 86400 + nums[0] * 3600 + nums[1] * 60 + nums[2]
    return 0


def _argv_flag(args, flag):
    parts = (args or "").split()
    for i, part in enumerate(parts):
        if part == flag and i + 1 < len(parts):
            return parts[i + 1]
        prefix = flag + "="
        if part.startswith(prefix):
            return part[len(prefix):]
    return None


def _xcodebuild_action(args):
    found = None
    for part in (args or "").split()[1:]:
        if part in ACTIONS:
            found = part
    return found or "build"


def _is_xcodebuild(proc):
    return _basename_cmd(proc.get("args")) == "xcodebuild"


def _is_swift_build(proc):
    """`swift build` / `swift test` — SPM CLI, not the language runtime."""
    if _basename_cmd(proc.get("args")) != "swift":
        return False
    parts = (proc.get("args") or "").split()
    return any(p in ("build", "test") for p in parts[1:3])


def _is_compiler(proc):
    return _basename_cmd(proc.get("args")) in COMPILER_CMDS


def _is_build_service(proc):
    return _basename_cmd(proc.get("args")) in BUILD_SERVICES


def _list_procs():
    """Return [{pid, ppid, age_s, args}], newest first is not required."""
    try:
        raw = subprocess.check_output(
            ["ps", "-axo", "pid=,ppid=,etime=,args="],
            stderr=subprocess.DEVNULL,
            timeout=8,
            text=True,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired,
            FileNotFoundError, OSError):
        return []

    rows = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
        except ValueError:
            continue
        rows.append({
            "pid": pid,
            "ppid": ppid,
            "age_s": _parse_etime(parts[2]),
            "args": parts[3],
        })
    return rows


def _cwds_for_pids(pids):
    out = {}
    ids = sorted({int(p) for p in pids if p})
    if not ids:
        return out
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

    for line in raw.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 9 or parts[3] != "cwd":
            continue
        try:
            pid = int(parts[1])
        except ValueError:
            continue
        path = parts[-1] if parts[-1].startswith("/") else " ".join(parts[8:])
        if path.startswith("/"):
            out[pid] = path
    return out


def _descendants(root_pid, by_pid):
    children = {}
    for proc in by_pid.values():
        children.setdefault(proc["ppid"], []).append(proc["pid"])
    found = set()
    stack = list(children.get(root_pid, ()))
    while stack:
        pid = stack.pop()
        if pid in found:
            continue
        found.add(pid)
        stack.extend(children.get(pid, ()))
    return found


def _ancestors(proc, by_pid, limit=12):
    cur = proc
    for _ in range(limit):
        parent = by_pid.get(cur["ppid"])
        if parent is None:
            return
        yield parent
        cur = parent


def _find_build_ancestor(proc, by_pid):
    for ancestor in _ancestors(proc, by_pid):
        if _is_xcodebuild(ancestor) or _is_build_service(ancestor):
            return ancestor
    return None


def _derived_folder(args):
    match = DERIVED_RE.search(args or "")
    if not match:
        return None
    # match.group(0) is /DerivedData/Name-hash/ or without trailing slash.
    return match.group(0).rstrip("/").split("/")[-1]


def _workspace_for_derived(folder):
    """Cached WorkspacePath from DerivedData/<folder>/Info.plist."""
    if folder in _derived_cache:
        return _derived_cache[folder]
    path = os.path.expanduser(
        f"~/Library/Developer/Xcode/DerivedData/{folder}/Info.plist")
    workspace = None
    try:
        with open(path, "rb") as handle:
            info = plistlib.load(handle)
        workspace = info.get("WorkspacePath") or None
    except (OSError, plistlib.InvalidFileException, ValueError):
        workspace = None
    _derived_cache[folder] = workspace
    return workspace


def _project_label_from_path(path):
    if not path:
        return None
    base = os.path.basename(path.rstrip("/"))
    for suffix in (".xcworkspace", ".xcodeproj", ".swiftpm"):
        if base.endswith(suffix):
            return base[: -len(suffix)]
    return base or None


def _dir_label(cwd):
    if not cwd:
        return None
    path = os.path.abspath(cwd.rstrip("/"))
    home = os.path.expanduser("~")
    if path in ("/", home):
        return None
    base = os.path.basename(path)
    if not base or base in (".", "..", "tmp", "Temp", "var", "private"):
        return None
    return _truncate(base)


def _label_bits(args, cwd=None):
    """Return (name, scheme, target, cwd_hint) from argv + optional cwd."""
    scheme = _argv_flag(args, "-scheme")
    project = _argv_flag(args, "-project")
    workspace = _argv_flag(args, "-workspace")
    target = None
    if workspace:
        target = os.path.basename(workspace.rstrip("/"))
    elif project:
        target = os.path.basename(project.rstrip("/"))

    derived = _derived_folder(args)
    if derived and not target:
        ws = _workspace_for_derived(derived)
        target = os.path.basename(ws.rstrip("/")) if ws else None
        if not scheme:
            # DerivedData folder is Name-hash; strip the hash.
            name_part = derived.rsplit("-", 1)[0]
            if name_part:
                scheme = name_part

    name = (
        _truncate(scheme)
        or _truncate(_project_label_from_path(
            workspace or project
            or (_workspace_for_derived(derived) if derived else None)))
        or _dir_label(cwd)
        or "Xcode"
    )
    return name, scheme, target, cwd


def _row(*, name, kind, action, scheme, target, pid, cmd, cwd, age_s):
    return {
        "name": name,
        "kind": kind,
        "action": action,
        "scheme": scheme,
        "target": target,
        "pid": pid,
        "cmd": cmd,
        "cwd": cwd,
        "age_s": int(age_s) if age_s is not None else 0,
    }


def _rows_from_cli(procs, by_pid, cwds):
    rows = []
    claimed = set()
    for proc in procs:
        if _is_xcodebuild(proc):
            cwd = cwds.get(proc["pid"])
            name, scheme, target, cwd = _label_bits(proc["args"], cwd)
            rows.append(_row(
                name=name,
                kind="xcodebuild",
                action=_xcodebuild_action(proc["args"]),
                scheme=scheme,
                target=target,
                pid=proc["pid"],
                cmd="xcodebuild",
                cwd=cwd,
                age_s=proc["age_s"],
            ))
            claimed.add(proc["pid"])
            claimed.update(_descendants(proc["pid"], by_pid))
            continue
        if _is_swift_build(proc):
            cwd = cwds.get(proc["pid"])
            name = _dir_label(cwd) or "Swift"
            action = "test" if " test" in f" {proc['args']} " else "build"
            rows.append(_row(
                name=name,
                kind="spm",
                action=action,
                scheme=None,
                target=None,
                pid=proc["pid"],
                cmd="swift",
                cwd=cwd,
                age_s=proc["age_s"],
            ))
            claimed.add(proc["pid"])
            claimed.update(_descendants(proc["pid"], by_pid))
    return rows, claimed


def _rows_from_ide(procs, by_pid, cwds, claimed):
    """One row per DerivedData / workspace currently compiling in Xcode."""
    groups = {}
    for proc in procs:
        if proc["pid"] in claimed or not _is_compiler(proc):
            continue
        ancestor = _find_build_ancestor(proc, by_pid)
        if ancestor is None or _is_xcodebuild(ancestor):
            continue
        # Prefer the compiler's args (DerivedData paths), else the service.
        name, scheme, target, _ = _label_bits(proc["args"])
        if name == "Xcode":
            name, scheme, target, _ = _label_bits(ancestor["args"])
        cwd = cwds.get(ancestor["pid"]) or cwds.get(proc["pid"])
        if name == "Xcode" and cwd:
            name = _dir_label(cwd) or name
        # Group key: derived folder, else scheme/target, else service pid.
        derived = _derived_folder(proc["args"]) or _derived_folder(
            ancestor["args"])
        key = derived or scheme or target or str(ancestor["pid"])
        group = groups.get(key)
        if group is None:
            groups[key] = _row(
                name=name,
                kind="xcode",
                action="build",
                scheme=scheme,
                target=target,
                pid=ancestor["pid"],
                cmd=_basename_cmd(ancestor["args"]) or "Xcode",
                cwd=cwd,
                age_s=proc["age_s"],
            )
        else:
            # Oldest compiler ≈ how long this build has been working.
            if proc["age_s"] > group["age_s"]:
                group["age_s"] = proc["age_s"]
            if not group.get("scheme") and scheme:
                group["scheme"] = scheme
            if not group.get("target") and target:
                group["target"] = target
            if group["name"] == "Xcode" and name != "Xcode":
                group["name"] = name
            if not group.get("cwd") and cwd:
                group["cwd"] = cwd
    return list(groups.values())


def fetch_builds(force=False):
    """Return {ok, host, builds:[{…}], error}."""
    now = time.time()
    if cache_util.fresh(_cache, now, CACHE_TTL_S, FAIL_TTL_S, force):
        return _cache["data"]

    host = _hostname()
    empty = {"ok": False, "host": host, "builds": [], "error": None}
    try:
        procs = _list_procs()
        by_pid = {p["pid"]: p for p in procs}
        # cwd only for build roots we might label — cheap when nothing builds.
        interest = [
            p["pid"] for p in procs
            if _is_xcodebuild(p) or _is_swift_build(p) or _is_build_service(p)
        ]
        cwds = _cwds_for_pids(interest)

        cli_rows, claimed = _rows_from_cli(procs, by_pid, cwds)
        ide_rows = _rows_from_ide(procs, by_pid, cwds, claimed)
        rows = cli_rows + ide_rows

        # Named projects first, then longer-running.
        rows.sort(key=lambda r: (
            0 if r.get("name") and r["name"] != "Xcode" else 1,
            -(r.get("age_s") or 0),
            r.get("name") or "",
        ))
        out = {
            "ok": True,
            "host": host,
            "builds": rows[:KEEP],
            "error": None,
            "stale": False,
        }
        _cache.update(t=now, data=out, err=None)
        return out
    except Exception as exc:
        return cache_util.keep_stale(_cache, now, str(exc), empty)
