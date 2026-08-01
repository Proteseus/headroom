"""Safe installer for Headroom-owned Claude Code HTTP hooks."""

from __future__ import annotations

import json
import os
import shutil
import tempfile
import urllib.parse

VERSION = 3
DEFAULT_SETTINGS_PATH = os.path.expanduser("~/.claude/settings.json")
MANAGED_PATH_PREFIX = "/agents/hooks/claude/"
# PreToolUse is not in the always-installed set. It is the only hook here that
# can block a tool call, so it is installed only when remote answering is
# switched on — see app_config.agent_question_mode.
EVENTS = (
    "PermissionRequest",
    "UserPromptSubmit",
    "Stop",
    "Notification",
    "SessionEnd",
)
OPTIONAL_EVENTS = ("PreToolUse",)

# PreToolUse fires for every tool call, which is far more traffic than the
# gateway wants. Scoped to the one tool whose answer Headroom can carry back:
# a denied call is the only hook path documented to show Claude a reason.
MATCHERS = {"PreToolUse": "AskUserQuestion"}

ENDPOINTS = {
    "PermissionRequest": "permission",
    "PreToolUse": "question",
}

# How long each hook may park while a phone decides. A question waits far less
# than an approval: the approval has nowhere else to be answered, while a
# question is sitting unanswerable on the Mac for exactly as long as we hold
# it. The value must stay above the adapter's own wait so the timeout that
# fires is ours, with a decision, rather than Claude's, with none.
TIMEOUTS = {"PermissionRequest": 300, "PreToolUse": 125}
# In notify mode the hook posts and returns, so it needs no more time than the
# other observing hooks — and holds nothing if the host is slow or gone.
NOTIFY_TIMEOUT = 5


def _url(port, event):
    endpoint = ENDPOINTS.get(event, "event")
    query = urllib.parse.urlencode({
        "managed_by": "headroom",
        "version": VERSION,
    })
    return f"http://127.0.0.1:{int(port)}{MANAGED_PATH_PREFIX}{endpoint}?{query}"


def _entry(port, event, question_mode="notify"):
    timeout = TIMEOUTS.get(event, 5)
    if event == "PreToolUse" and question_mode != "answer":
        timeout = NOTIFY_TIMEOUT
    hook = {
        "type": "http",
        "url": _url(port, event),
        "timeout": timeout,
    }
    return {"matcher": MATCHERS.get(event, ""), "hooks": [hook]}


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


def install(path=DEFAULT_SETTINGS_PATH, port=8737, question_mode="notify"):
    """Install the observing hooks, plus the question hook unless it is off.

    `notify` installs PreToolUse with the same short timeout as every other
    observing hook: it posts the question and returns, so the question shows
    up in both places and nothing is ever held. `answer` gives it the long
    timeout it needs to wait for a phone answer. `off` removes it.
    """
    remote_questions = question_mode in ("notify", "answer")
    path = os.path.expanduser(path)
    value = _read(path)
    hooks = value.get("hooks")
    hooks = hooks if isinstance(hooks, dict) else {}
    for event in OPTIONAL_EVENTS:
        entries = hooks.get(event)
        entries = entries if isinstance(entries, list) else []
        entries = [entry for entry in entries if not _managed(entry)]
        if remote_questions:
            entries.append(_entry(port, event, question_mode))
        if entries:
            hooks[event] = entries
        else:
            hooks.pop(event, None)
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
