"""Personal Headroom config (~/.headroom/config.json).

Keeps machine-specific paths, timezone, git authors, Vercel team preference,
and GitHub org filters out of the code. Missing keys fall back to the defaults
below — copy config.example.json to ~/.headroom/config.json and edit.
"""

from __future__ import annotations

import json
import os
import threading

STORE_PATH = os.path.expanduser("~/.headroom/config.json")

DEFAULTS = {
    "timezone": "UTC",
    "dev_root": "~/Dev",
    "git_authors": [],
    "vercel_team_slugs": [],
    "github_org_prefix": "",
    "github_always_repos": [],
    "github_max_discovered": 6,
    "plausible_sites": [],
    "plausible_host": "https://plausible.io",
    "plausible_range": "24h",
    # Authenticated iOS clients may use only these capabilities, and only from
    # a private/Tailscale address. Credential management remains Mac-local.
    "mobile_permissions": ["read", "refresh", "sources", "servers"],
}

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


def github_org_prefix():
    value = get("github_org_prefix")
    if value is None:
        return DEFAULTS["github_org_prefix"]
    return str(value)


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
    data = _load()
    data["plausible_range"] = rid
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
    return rid


MOBILE_PERMISSION_ORDER = ("read", "refresh", "sources", "servers")


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
    data = _load()
    data["mobile_permissions"] = ordered
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
    return frozenset(ordered)


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
    data = _load()
    data["attention_ack_fingerprint"] = fingerprint
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
    return fingerprint
