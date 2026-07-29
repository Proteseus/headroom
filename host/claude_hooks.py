"""Safe installer for Headroom-owned Claude Code HTTP hooks."""

from __future__ import annotations

import json
import os
import shutil
import tempfile
import urllib.parse

VERSION = 1
DEFAULT_SETTINGS_PATH = os.path.expanduser("~/.claude/settings.json")
MANAGED_PATH_PREFIX = "/agents/hooks/claude/"
EVENTS = (
    "PermissionRequest",
    "UserPromptSubmit",
    "Stop",
    "Notification",
    "SessionEnd",
)


def _url(port, event):
    endpoint = "permission" if event == "PermissionRequest" else "event"
    query = urllib.parse.urlencode({
        "managed_by": "headroom",
        "version": VERSION,
    })
    return f"http://127.0.0.1:{int(port)}{MANAGED_PATH_PREFIX}{endpoint}?{query}"


def _entry(port, event):
    hook = {
        "type": "http",
        "url": _url(port, event),
        "timeout": 300 if event == "PermissionRequest" else 5,
    }
    return {"matcher": "", "hooks": [hook]}


def _managed(entry):
    if not isinstance(entry, dict):
        return False
    hooks = entry.get("hooks")
    if not isinstance(hooks, list):
        return False
    for hook in hooks:
        if not isinstance(hook, dict):
            continue
        value = hook.get("url")
        if not isinstance(value, str):
            continue
        parsed = urllib.parse.urlsplit(value)
        if (parsed.hostname in ("127.0.0.1", "localhost")
                and parsed.path.startswith(MANAGED_PATH_PREFIX)
                and urllib.parse.parse_qs(parsed.query).get(
                    "managed_by") == ["headroom"]):
            return True
    return False


def _read(path):
    try:
        with open(path) as handle:
            value = json.load(handle)
    except FileNotFoundError:
        return {}
    if not isinstance(value, dict):
        raise ValueError("Claude settings must contain a JSON object")
    return value


def _write(path, value):
    folder = os.path.dirname(path)
    os.makedirs(folder, mode=0o700, exist_ok=True)
    if os.path.exists(path):
        shutil.copy2(path, path + ".bak-headroom")
    fd, temporary = tempfile.mkstemp(
        prefix=".settings-headroom-", suffix=".json", dir=folder)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def inspect(path=DEFAULT_SETTINGS_PATH, port=8737):
    path = os.path.expanduser(path)
    value = _read(path)
    hooks = value.get("hooks")
    hooks = hooks if isinstance(hooks, dict) else {}
    installed = []
    current = []
    for event in EVENTS:
        entries = hooks.get(event)
        entries = entries if isinstance(entries, list) else []
        managed = [entry for entry in entries if _managed(entry)]
        if managed:
            installed.append(event)
        if any(entry == _entry(port, event) for entry in managed):
            current.append(event)
    if not installed:
        state = "not_installed"
    elif set(current) == set(EVENTS):
        state = "installed"
    elif set(installed) == set(EVENTS):
        state = "outdated"
    else:
        state = "modified_externally"
    return {
        "provider": "claude-code",
        "settings_path": path,
        "state": state,
        "installed": state == "installed",
        "installed_events": installed,
        "version": VERSION if installed else None,
    }


def install(path=DEFAULT_SETTINGS_PATH, port=8737):
    path = os.path.expanduser(path)
    value = _read(path)
    hooks = value.get("hooks")
    hooks = hooks if isinstance(hooks, dict) else {}
    for event in EVENTS:
        entries = hooks.get(event)
        entries = entries if isinstance(entries, list) else []
        entries = [entry for entry in entries if not _managed(entry)]
        entries.append(_entry(port, event))
        hooks[event] = entries
    value["hooks"] = hooks
    _write(path, value)
    return inspect(path, port)


def uninstall(path=DEFAULT_SETTINGS_PATH, port=8737):
    path = os.path.expanduser(path)
    value = _read(path)
    hooks = value.get("hooks")
    if not isinstance(hooks, dict):
        return inspect(path, port)
    for event in list(hooks):
        entries = hooks.get(event)
        if not isinstance(entries, list):
            continue
        remaining = [entry for entry in entries if not _managed(entry)]
        if remaining:
            hooks[event] = remaining
        else:
            hooks.pop(event, None)
    if hooks:
        value["hooks"] = hooks
    else:
        value.pop("hooks", None)
    _write(path, value)
    return inspect(path, port)
