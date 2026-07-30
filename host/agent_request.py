"""Provider-neutral rendering of a coding agent's actual request.

An approval is only meaningful if you can see what you are approving. Adapters
hand this module the provider's raw request object; it returns an ordered list
of typed fields that any client can render without knowing the tool.

The shape is deliberately flat and self-describing — `key` is the provider's
own name, `label` is for humans, `kind` tells a client how to draw it. A tool
this module has never heard of still renders, just in sorted key order.

Bounds are enforced here rather than at the client, because the ledger, the
HTTP response and the phone all pay for an unbounded `content` field on a
Write of a large file.
"""

from __future__ import annotations

import json

MAX_FIELD_CHARS = 2000
MAX_FIELDS = 24
MAX_TOTAL_CHARS = 12000

KINDS = ("text", "command", "code", "path", "json", "number", "bool")

# Field order for the tools whose shape we know. Anything omitted here still
# appears, sorted, after the known keys — an MCP tool is not a special case.
KNOWN_ORDER = {
    "Bash": ("command", "description", "timeout", "run_in_background"),
    "Edit": ("file_path", "old_string", "new_string", "replace_all"),
    "Write": ("file_path", "content"),
    "Read": ("file_path", "offset", "limit", "pages"),
    "NotebookEdit": ("notebook_path", "cell_id", "edit_mode", "new_source"),
    "WebFetch": ("url", "prompt"),
    "WebSearch": ("query", "allowed_domains", "blocked_domains"),
    "Glob": ("pattern", "path"),
    "Grep": ("pattern", "path", "glob", "output_mode"),
    "Task": ("subagent_type", "description", "prompt"),
}

LABELS = {
    "command": "Command",
    "description": "Description",
    "timeout": "Timeout",
    "run_in_background": "Run in background",
    "file_path": "File",
    "notebook_path": "Notebook",
    "old_string": "Replacing",
    "new_string": "With",
    "new_source": "New source",
    "replace_all": "Replace all",
    "content": "Content",
    "cell_id": "Cell",
    "edit_mode": "Edit mode",
    "offset": "From line",
    "limit": "Lines",
    "pages": "Pages",
    "url": "URL",
    "prompt": "Prompt",
    "query": "Query",
    "pattern": "Pattern",
    "path": "Path",
    "glob": "Glob",
    "output_mode": "Output",
    "subagent_type": "Agent",
    "cwd": "Working directory",
}

CODE_KEYS = frozenset({
    "content", "new_string", "old_string", "new_source", "prompt", "code",
    "script", "body", "patch", "diff",
})

PATH_KEYS = frozenset({"file_path", "notebook_path", "path", "cwd", "dir"})

COMMAND_KEYS = frozenset({"command", "cmd"})


def _label(key):
    known = LABELS.get(key)
    if known is not None:
        return known
    return key.replace("_", " ").replace("-", " ").strip().capitalize() or key


def _kind(key, value):
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, (dict, list)):
        return "json"
    if key in COMMAND_KEYS:
        return "command"
    if key in PATH_KEYS or key.endswith("_path"):
        return "path"
    if key in CODE_KEYS:
        return "code"
    return "text"


def _render(value):
    """Stringify a JSON value the way a person reads it, not the way it stores."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return ""
    if isinstance(value, (dict, list)):
        try:
            return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False)
        except (TypeError, ValueError):
            return str(value)
    return str(value)


def _clip(text, limit):
    if limit <= 0 or len(text) <= limit:
        return text, False
    return text[:limit], True


def _ordered_keys(tool_name, payload):
    known = KNOWN_ORDER.get(tool_name, ())
    first = [key for key in known if key in payload]
    rest = sorted(key for key in payload if key not in first)
    return first + rest


def fields(payload, tool_name=None):
    """Turn a provider request object into ordered, bounded, typed fields.

    Returns `[]` for anything that is not an object, so a caller can treat an
    absent request and an unusable one the same way.
    """
    if not isinstance(payload, dict) or not payload:
        return []
    result = []
    budget = MAX_TOTAL_CHARS
    keys = _ordered_keys(tool_name, payload)
    omitted = max(0, len(keys) - MAX_FIELDS)
    for key in keys[:MAX_FIELDS]:
        if not isinstance(key, str):
            continue
        value = payload[key]
        text = _render(value)
        if not text and not isinstance(value, bool):
            continue
        full = len(text)
        text, clipped = _clip(text, min(MAX_FIELD_CHARS, budget))
        budget -= len(text)
        result.append({
            "key": key,
            "label": _label(key),
            "kind": _kind(key, value),
            "value": text,
            "truncated": clipped,
            "full_chars": full,
        })
        if budget <= 0:
            omitted += len(keys[:MAX_FIELDS]) - len(result)
            break
    if omitted > 0 and result:
        result[-1]["omitted_fields"] = omitted
    return result


def summary(payload, tool_name, fallback=None):
    """One line for a notification or a collapsed row.

    Prefers the field a person would recognise the request by, which is not
    always the first one the provider happens to send.
    """
    fallback = fallback or (f"Use {tool_name}" if tool_name else "Agent request")
    if not isinstance(payload, dict):
        return fallback
    for key in ("command", "description", "query", "url", "pattern"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return _one_line(value)
    for key in ("file_path", "notebook_path", "path"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            verb = {"Write": "Write", "Edit": "Edit", "Read": "Read"}.get(
                tool_name, tool_name or "Use")
            return _one_line(f"{verb} {value.strip()}")
    return fallback


def _one_line(value, limit=240):
    text = " ".join(str(value or "").split())
    if not text:
        return ""
    return text if len(text) <= limit else text[:limit - 1] + "…"
