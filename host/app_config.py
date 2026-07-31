"""Personal Headroom config (~/.headroom/config.json).

Keeps machine-specific paths, timezone, git authors, Vercel team preference,
and GitHub org filters out of the code. Missing keys fall back to the defaults
below — copy config.example.json to ~/.headroom/config.json and edit.
"""

from __future__ import annotations

import json
import os
import re
import threading

STORE_PATH = os.path.expanduser("~/.headroom/config.json")

DEFAULTS = {
    "timezone": "UTC",
    "dev_root": "~/Dev",
    "git_authors": [],
    "vercel_team_slugs": [],
    # String or list of strings; see github_org_prefixes().
    "github_org_prefix": [],
    "github_always_repos": [],
    "github_max_discovered": 6,
    "plausible_sites": [],
    "plausible_host": "https://plausible.io",
    "plausible_range": "24h",
    # Authenticated iOS clients may use only these capabilities, and only from
    # a private/Tailscale address. Credential management remains Mac-local.
    "mobile_permissions": ["read", "refresh", "sources", "servers"],
    # The agent gateway is opt-in while its protocol and remote-control
    # surfaces are being introduced. Merely installing/updating Headroom must
    # never launch a coding agent behind the user's back.
    "agent_gateway_enabled": False,
    "codex_binary": "codex",
    # Multi-Mac. Off until asked for: sync writes usage data to a folder that
    # leaves the machine, and installing Headroom must not start doing that on
    # its own. See icloud_sync.py and docs/multi-mac.md.
    "icloud_sync": False,
    # Where peer machines meet. Empty means the default iCloud Drive folder;
    # point it anywhere that syncs (Dropbox, Syncthing) and the rest works
    # unchanged — nothing here is iCloud-specific but the default path.
    "icloud_dir": "",
}

# Config keys that are the same person's answer on every Mac, so they follow
# them from one to the next. Everything absent from this tuple stays local,
# and two of those absences are load-bearing: `auth_token` is a credential,
# and `dev_root` / `codex_binary` are paths that describe one machine's disk.
SHARED_CONFIG_KEYS = (
    "git_authors",
    "vercel_team_slugs",
    "github_org_prefix",
    "github_always_repos",
    "github_max_discovered",
    "plausible_sites",
    "plausible_host",
    "plausible_range",
)

_lock = threading.Lock()
_cache = None


def _load():
    try:
        with open(STORE_PATH) as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def reload():
    """Drop the in-memory cache (tests / after editing config.json)."""
    global _cache
    with _lock:
        _cache = None


def _persist(**updates):
    """Write keys into config.json, leaving every other key as the user left it.

    Read-modify-write through a temp file, 0600: this file holds an optional
    host token, and a half-written config would strand the app on defaults.
    """
    data = _load()
    data.update(updates)
    folder = os.path.dirname(STORE_PATH)
    os.makedirs(folder, exist_ok=True)
    tmp = STORE_PATH + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(data, handle, indent=2)
            handle.write("\n")
        os.replace(tmp, STORE_PATH)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    reload()


def raw():
    """Merged config: defaults overlaid by ~/.headroom/config.json."""
    global _cache
    with _lock:
        if _cache is None:
            merged = dict(DEFAULTS)
            merged.update(_load())
            _cache = merged
        return dict(_cache)


def get(key, default=None):
    cfg = raw()
    if key in cfg:
        return cfg[key]
    return default


def timezone_name():
    value = get("timezone") or DEFAULTS["timezone"]
    return str(value)


def dev_root():
    value = get("dev_root") or DEFAULTS["dev_root"]
    return os.path.expanduser(str(value))


def git_authors():
    value = get("git_authors")
    if isinstance(value, list) and value:
        return [str(item) for item in value if str(item).strip()]
    return list(DEFAULTS["git_authors"])


def vercel_team_slugs():
    value = get("vercel_team_slugs")
    if isinstance(value, list) and value:
        return tuple(str(item).lower() for item in value if str(item).strip())
    return tuple(DEFAULTS["vercel_team_slugs"])


def github_org_prefixes():
    """Org filters for discovered repos: one string, or a list of them.

    Personal work rarely lives under a single owner — a repo under your own
    handle is as much yours as one under the org. Empty means no filter.
    """
    value = get("github_org_prefix")
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, list):
        return tuple(DEFAULTS["github_org_prefix"])
    out = []
    for item in value:
        text = str(item).strip().lower()
        if text and text not in out:
            out.append(text)
    return tuple(out)


def github_always_repos():
    value = get("github_always_repos")
    if isinstance(value, list) and value:
        return tuple(str(item) for item in value if str(item).strip())
    return tuple(DEFAULTS["github_always_repos"])


def github_max_discovered():
    value = get("github_max_discovered", DEFAULTS["github_max_discovered"])
    try:
        return max(0, int(value))
    except (TypeError, ValueError):
        return int(DEFAULTS["github_max_discovered"])


GITHUB_MAX_DISCOVERED_LIMIT = 50
GITHUB_LIST_LIMIT = 50
# owner/name, the only shape the Actions API takes.
_REPO_SLUG = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")


def _clean_list(values, label):
    if isinstance(values, str):
        values = [values]
    if not isinstance(values, (list, tuple)):
        raise ValueError(f"{label} must be a list")
    out = []
    for item in values:
        text = str(item).strip()
        if not text:
            continue
        if text not in out:
            out.append(text)
    if len(out) > GITHUB_LIST_LIMIT:
        raise ValueError(f"{label}: at most {GITHUB_LIST_LIMIT} entries")
    return out


def set_github_watch(prefixes=None, always_repos=None, max_discovered=None):
    """Persist which Actions repos to watch. A None argument leaves that key.

    Raises ValueError with something worth showing a person: this is reached
    from Settings, where a typo like "acme" instead of "acme/api" is the most
    likely input and silently dropping it would read as the save failing.
    """
    updates = {}
    if prefixes is not None:
        updates["github_org_prefix"] = [
            item.lower() for item in _clean_list(prefixes, "owners")
        ]
    if always_repos is not None:
        repos = _clean_list(always_repos, "always_repos")
        for repo in repos:
            if not _REPO_SLUG.match(repo):
                raise ValueError(f"{repo!r} is not owner/name")
        updates["github_always_repos"] = repos
    if max_discovered is not None:
        try:
            count = int(max_discovered)
        except (TypeError, ValueError):
            raise ValueError("max_discovered must be a number") from None
        updates["github_max_discovered"] = max(
            0, min(GITHUB_MAX_DISCOVERED_LIMIT, count))
    if updates:
        _persist(**updates)
    return {
        "owners": list(github_org_prefixes()),
        "always_repos": list(github_always_repos()),
        "max_discovered": github_max_discovered(),
    }


def plausible_sites():
    value = get("plausible_sites")
    if isinstance(value, list) and value:
        return tuple(str(item).strip() for item in value if str(item).strip())
    return tuple(DEFAULTS["plausible_sites"])


def plausible_host():
    value = get("plausible_host") or DEFAULTS["plausible_host"]
    return str(value).rstrip("/") or DEFAULTS["plausible_host"]


PLAUSIBLE_RANGES = ("day", "24h", "7d", "30d")
PLAUSIBLE_RANGE_LABELS = {
    "day": "today",
    "24h": "24h",
    "7d": "7d",
    "30d": "30d",
}


def plausible_range():
    value = str(get("plausible_range") or DEFAULTS["plausible_range"]).strip().lower()
    return value if value in PLAUSIBLE_RANGES else DEFAULTS["plausible_range"]


def plausible_range_label(range_id=None):
    rid = range_id or plausible_range()
    return PLAUSIBLE_RANGE_LABELS.get(rid, rid)


def set_plausible_range(value):
    """Persist the primary Plausible window without disturbing other config."""
    rid = str(value or "").strip().lower()
    if rid not in PLAUSIBLE_RANGES:
        raise ValueError(
            f"plausible_range must be one of {', '.join(PLAUSIBLE_RANGES)}")
    _persist(plausible_range=rid)
    return rid


MOBILE_PERMISSION_ORDER = ("read", "refresh", "sources", "servers", "agents")


def mobile_permissions():
    value = get("mobile_permissions", DEFAULTS["mobile_permissions"])
    if not isinstance(value, list):
        return frozenset()
    allowed = set(MOBILE_PERMISSION_ORDER)
    return frozenset(str(item) for item in value if str(item) in allowed)


def set_mobile_permissions(values):
    """Persist the Mac-owned capability set without disturbing other config."""
    selected = {
        str(item) for item in values
        if str(item) in MOBILE_PERMISSION_ORDER
    }
    ordered = [item for item in MOBILE_PERMISSION_ORDER if item in selected]
    _persist(mobile_permissions=ordered)
    return frozenset(ordered)


MAX_TASK_FOLDERS = 8


def task_folders():
    """Folders you have started agent work in, most recent first.

    The Mac can open a folder picker; a phone cannot browse the Mac's disk, so
    it picks from what the Mac has already used.
    """
    value = get("agent_task_folders")
    if not isinstance(value, list):
        return []
    return [entry for entry in value
            if isinstance(entry, str) and entry][:MAX_TASK_FOLDERS]


def remember_task_folder(folder):
    """Move a folder to the front of the list, without duplicating it."""
    if not isinstance(folder, str) or not folder.strip():
        return task_folders()
    folder = folder.strip()
    remaining = [entry for entry in task_folders() if entry != folder]
    ordered = [folder] + remaining
    ordered = ordered[:MAX_TASK_FOLDERS]
    _persist(agent_task_folders=ordered)
    return ordered


def agent_remote_questions():
    """Whether Headroom may hold a Claude question open for a phone answer.

    Off by default, and deliberately so. Intercepting a question at
    `PreToolUse` is the only way to answer it remotely, but it also makes the
    question unanswerable at the Mac while Headroom holds it — and if the host
    is down or restarting, every question in every session pays for it. That
    is a bad trade unless you actually want to answer from your phone.
    """
    return get("agent_remote_questions") is True


def set_agent_remote_questions(enabled):
    if not isinstance(enabled, bool):
        raise ValueError("enabled must be true or false")
    _persist(agent_remote_questions=enabled)
    return enabled


def agent_gateway_enabled():
    """Whether Headroom may launch its supervised coding-agent adapter."""
    return get("agent_gateway_enabled") is True


def codex_binary():
    """Executable used for the Codex App Server child process."""
    value = str(get("codex_binary") or DEFAULTS["codex_binary"]).strip()
    return os.path.expanduser(value or DEFAULTS["codex_binary"])


def set_agent_gateway(enabled=None, codex_binary_value=None):
    """Persist the Mac-owned Codex gateway settings."""
    updates = {}
    if enabled is not None:
        if not isinstance(enabled, bool):
            raise ValueError("enabled must be true or false")
        updates["agent_gateway_enabled"] = enabled
    if codex_binary_value is not None:
        if not isinstance(codex_binary_value, str):
            raise ValueError("codex_binary must be a string")
        binary = codex_binary_value.strip()
        if not binary or len(binary) > 4096 or "\x00" in binary:
            raise ValueError("invalid codex_binary")
        updates["codex_binary"] = binary
    if updates:
        _persist(**updates)
    return {
        "enabled": agent_gateway_enabled(),
        "codex_binary": codex_binary(),
    }


def icloud_sync_enabled():
    """Whether this Mac publishes to, and reads, the shared machine folder."""
    return get("icloud_sync") is True


def icloud_dir():
    """Configured sync folder, or None to let icloud_sync pick the default."""
    value = str(get("icloud_dir") or "").strip()
    return os.path.expanduser(value) if value else None


def set_icloud_sync(enabled=None, directory=None):
    """Persist the multi-Mac settings. Returns them as stored."""
    updates = {}
    if enabled is not None:
        if not isinstance(enabled, bool):
            raise ValueError("enabled must be true or false")
        updates["icloud_sync"] = enabled
    if directory is not None:
        if not isinstance(directory, str):
            raise ValueError("directory must be a string")
        folder = directory.strip()
        if len(folder) > 4096 or "\x00" in folder:
            raise ValueError("invalid directory")
        updates["icloud_dir"] = folder
    if updates:
        _persist(**updates)
    return {"enabled": icloud_sync_enabled(), "directory": icloud_dir()}


def shared_config():
    """The synced subset of config.json, as stored (absent keys omitted).

    Reads the file rather than `raw()` so a key the user has never set stays
    absent instead of syncing this build's default out to every other Mac as
    though it were a choice.
    """
    data = _load()
    return {k: data[k] for k in SHARED_CONFIG_KEYS if k in data}


def set_shared_config(updates):
    """Write synced config keys. Anything outside the whitelist is ignored.

    The filter is here rather than in the caller on purpose: this module owns
    the file that holds the host token, so it is the right place to be sure a
    sync can never write one.
    """
    clean = {
        k: v for k, v in (updates or {}).items() if k in SHARED_CONFIG_KEYS
    }
    if clean:
        _persist(**clean)
    return clean


def attention_ack_fingerprint():
    value = get("attention_ack_fingerprint")
    if not isinstance(value, str):
        return None
    value = value.strip()
    return value or None


def set_attention_ack_fingerprint(value):
    """Persist acknowledge-until-new state shared by every client surface."""
    fingerprint = str(value or "").strip()
    if not fingerprint or len(fingerprint) > 4096:
        raise ValueError("invalid attention fingerprint")
    _persist(attention_ack_fingerprint=fingerprint)
    return fingerprint
