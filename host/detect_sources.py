"""Cheap local probes for first-run source defaults.

No network. Used to seed ~/.headroom/sources.json so a Claude-only machine
doesn't poll empty Codex/Cursor (and vice versa). Stdlib only.
"""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess

import app_config


def claude_signed_in():
    try:
        raw = subprocess.check_output(
            ["security", "find-generic-password",
             "-s", "Claude Code-credentials", "-w"],
            stderr=subprocess.DEVNULL, text=True,
        ).strip()
        if raw:
            blob = json.loads(raw)
            if (blob.get("claudeAiOauth") or {}).get("accessToken"):
                return True
    except (subprocess.CalledProcessError, FileNotFoundError,
            json.JSONDecodeError, TypeError):
        pass
    path = os.path.expanduser("~/.claude/.credentials.json")
    try:
        with open(path) as handle:
            blob = json.load(handle)
        return bool((blob.get("claudeAiOauth") or {}).get("accessToken"))
    except (OSError, json.JSONDecodeError, TypeError):
        return False


def codex_signed_in():
    home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
    path = os.path.join(home, "auth.json")
    try:
        with open(path) as handle:
            blob = json.load(handle)
        return bool((blob.get("tokens") or {}).get("access_token"))
    except (OSError, json.JSONDecodeError, TypeError):
        return False


def cursor_signed_in():
    path = os.path.expanduser(
        "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    )
    if not os.path.isfile(path):
        return False
    try:
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            row = con.execute(
                "SELECT value FROM ItemTable WHERE key = ?",
                ("cursorAuth/accessToken",),
            ).fetchone()
        finally:
            con.close()
    except sqlite3.Error:
        return False
    if not row or row[0] is None:
        return False
    val = row[0]
    if isinstance(val, bytes):
        val = val.decode("utf-8", errors="replace")
    return bool(str(val).strip())


def vercel_signed_in():
    path = os.path.expanduser(
        "~/Library/Application Support/com.vercel.cli/auth.json"
    )
    try:
        with open(path) as handle:
            blob = json.load(handle)
        return bool(blob.get("token") or blob.get("refreshToken"))
    except (OSError, json.JSONDecodeError, TypeError):
        return False


def git_available():
    root = app_config.dev_root()
    if not os.path.isdir(root):
        return False
    # Cheap: root itself is a repo, or any immediate child is.
    if os.path.isdir(os.path.join(root, ".git")):
        return True
    try:
        for name in os.listdir(root):
            if os.path.isdir(os.path.join(root, name, ".git")):
                return True
    except OSError:
        return False
    return False


def github_signed_in():
    if os.environ.get("HEADROOM_GITHUB_TOKEN") or os.environ.get("GITHUB_TOKEN"):
        return True
    try:
        raw = subprocess.check_output(
            ["/usr/bin/security", "find-generic-password",
             "-s", "com.mz.headroom.github", "-a", "access-token", "-w"],
            stderr=subprocess.DEVNULL, text=True,
        ).strip()
        if raw:
            return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    hosts = os.path.expanduser("~/.config/gh/hosts.yml")
    return os.path.isfile(hosts)


def supabase_signed_in():
    if os.environ.get("SUPABASE_ACCESS_TOKEN"):
        return True
    try:
        raw = subprocess.check_output(
            ["/usr/bin/security", "find-generic-password",
             "-s", "com.mz.headroom.supabase", "-a", "access-token", "-w"],
            stderr=subprocess.DEVNULL, text=True,
        ).strip()
        if raw:
            return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    path = os.path.expanduser("~/.supabase/access-token")
    try:
        with open(path) as handle:
            return bool(handle.read().strip())
    except OSError:
        return False


def local_available():
    return True


PROBES = {
    "claude": claude_signed_in,
    "codex": codex_signed_in,
    "cursor": cursor_signed_in,
    "vercel": vercel_signed_in,
    "git": git_available,
    "github": github_signed_in,
    "local": local_available,
    "supabase": supabase_signed_in,
}


def detected_map():
    """{source_id: bool} for every known probe (missing ids omitted)."""
    out = {}
    for sid, probe in PROBES.items():
        try:
            out[sid] = bool(probe())
        except Exception:
            out[sid] = False
    return out


def suggested_enabled(source_ids):
    """First-run enabled flags: on only when a local credential/path exists.

    If no coding provider is detected, enable all quota sources so the UI
    still surfaces sign-in errors instead of an empty overview.
    """
    detected = detected_map()
    enabled = {sid: bool(detected.get(sid, False)) for sid in source_ids}
    quota_ids = [sid for sid in ("claude", "codex", "cursor") if sid in enabled]
    if quota_ids and not any(enabled[sid] for sid in quota_ids):
        for sid in quota_ids:
            enabled[sid] = True
    # Local servers need no auth and are useful on day one.
    if "local" in enabled:
        enabled["local"] = True
    return enabled
