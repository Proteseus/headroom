"""Recent local git commits by the desk owner for the gadget.

Scans ~/Dev/* (and one nested level, e.g. ~/Dev/envisioning/*) for git repos,
runs `git log` filtered to Michell / michellzappa / envisioning authors, merges
by time, and returns the newest few commits.

Stdlib only (subprocess). Failures degrade to {ok: false} / empty list.
"""

from __future__ import annotations

import os
import subprocess
import time

CACHE_TTL_S = 60
DEV_ROOT = os.path.expanduser("~/Dev")
PER_REPO = 15
KEEP = 6
# Match GitHub username, local name, and work emails (.io + .com).
AUTHOR_PATTERNS = (
    "michellzappa",
    "Michell Zappa",
    "mz@envisioning.io",
    "mz@envisioning.com",
)

_cache = {"t": 0.0, "data": None}


def fmt_ago(unix_ts):
    """Always hours since commit (e.g. 0h, 3h, 48h)."""
    if unix_ts is None:
        return None
    try:
        ago_s = max(0, int(time.time() - float(unix_ts)))
    except (TypeError, ValueError):
        return None
    return f"{ago_s // 3600}h"


def _is_git_repo(path):
    return os.path.isdir(os.path.join(path, ".git"))


def _discover_repos(root):
    """Top-level ~/Dev/* repos plus one nested level (envisioning/*, tiny/*, …)."""
    repos = []
    try:
        entries = os.listdir(root)
    except OSError:
        return repos
    for name in sorted(entries):
        if name.startswith("."):
            continue
        path = os.path.join(root, name)
        if not os.path.isdir(path):
            continue
        if _is_git_repo(path):
            repos.append(path)
            continue
        # Nested workspace folders (e.g. ~/Dev/envisioning/envisioning-core).
        try:
            children = os.listdir(path)
        except OSError:
            continue
        for child in sorted(children):
            if child.startswith("."):
                continue
            child_path = os.path.join(path, child)
            if os.path.isdir(child_path) and _is_git_repo(child_path):
                repos.append(child_path)
    return repos


def _git(cwd, *args):
    try:
        out = subprocess.check_output(
            ["git", *args],
            cwd=cwd,
            stderr=subprocess.DEVNULL,
            timeout=8,
        )
        return out.decode("utf-8", errors="replace")
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired,
            FileNotFoundError, OSError):
        return ""


def _branch(cwd):
    # Prefer symbolic name; fall back to short SHA of HEAD.
    b = _git(cwd, "rev-parse", "--abbrev-ref", "HEAD").strip()
    if b and b != "HEAD":
        return b
    return None


def _repo_name(path):
    """Local folder leaf only — never owner/account (owner/repo → repo)."""
    name = os.path.basename(path.rstrip(os.sep))
    if "/" in name:
        name = name.rsplit("/", 1)[-1]
    return name


def _remote_url(path):
    raw = _git(path, "remote", "get-url", "origin").strip()
    if not raw:
        return None
    if raw.startswith("git@github.com:"):
        return "https://github.com/" + raw.removeprefix(
            "git@github.com:").removesuffix(".git")
    if raw.startswith("https://github.com/"):
        return raw.removesuffix(".git")
    return None


def _log_repo(path):
    repo = _repo_name(path)
    branch = _branch(path)
    upstream = set(_git(
        path, "log", "-n200", "--pretty=format:%H", "@{upstream}"
    ).splitlines())
    # One --author per pattern; git ORs multiple --author flags.
    args = ["log", f"-n{PER_REPO}", "--date=unix",
            "--pretty=format:%H%x09%ct%x09%s"]
    for pat in AUTHOR_PATTERNS:
        args.extend(["--author", pat])
    raw = _git(path, *args)
    commits = []
    for line in raw.splitlines():
        if not line.strip() or "\t" not in line:
            continue
        parts = line.split("\t", 2)
        if len(parts) != 3:
            continue
        sha, ts_s, subject = parts
        try:
            ts = int(ts_s)
        except ValueError:
            continue
        subject = subject.strip()
        if not subject:
            continue
        commits.append({
            "repo": repo,
            "sha": sha,
            "subject": subject[:80],
            "t": ts,
            "ago": fmt_ago(ts),
            "branch": branch,
            "pushed": sha in upstream if upstream else None,
            "path": path,
            "repo_url": _remote_url(path),
        })
    return commits


def fetch_commits(force=False):
    """Return newest commits across ~/Dev authored by the owner."""
    now = time.time()
    if (not force and _cache["data"] is not None
            and now - _cache["t"] < CACHE_TTL_S):
        return _cache["data"]

    if not os.path.isdir(DEV_ROOT):
        out = {"ok": False, "error": f"missing {DEV_ROOT}", "commits": []}
        _cache.update(t=now, data=out)
        return out

    try:
        all_commits = []
        for path in _discover_repos(DEV_ROOT):
            all_commits.extend(_log_repo(path))
        all_commits.sort(key=lambda c: c["t"], reverse=True)
        slim = []
        for c in all_commits[:KEEP]:
            hours = max(0, int(now - c["t"])) // 3600
            repo = c["repo"]
            if "/" in repo:
                repo = repo.rsplit("/", 1)[-1]
            slim.append({
                "repo": repo,
                "sha": c["sha"],
                "short_sha": c["sha"][:7],
                "subject": c["subject"],
                "created_at": c["t"],
                "ago": f"{hours}h",
                "hours": hours,
                "branch": c["branch"],
                "pushed": c["pushed"],
                "path": c["path"],
                "repo_url": c["repo_url"],
            })
        out = {"ok": True, "error": None, "commits": slim}
    except Exception as exc:
        out = {"ok": False, "error": str(exc), "commits": []}

    _cache.update(t=now, data=out)
    return out
