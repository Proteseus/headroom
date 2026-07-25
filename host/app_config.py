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
