"""Claude Code hook adapter.

Claude's PermissionRequest HTTP hook remains open while Headroom presents the
request elsewhere. A phone response wakes that exact handler, which returns
Claude's documented allow/deny JSON. Passive lifecycle hooks use the same
ledger but never pretend they can answer a question they did not receive.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import threading
import time
import uuid

import agent_events
import agent_request
import claude_hooks

PROVIDER = "claude-code"
ADAPTER = "claude-http-hooks"
DEFAULT_WAIT_SECONDS = 285
# A question is usually answered at the keyboard. Holding one for the
# permission wait made it dead air on the Mac for nearly five minutes,
# which is worse than never offering it on the phone at all.
# Long enough for an iPhone foreground poll, notification tap, and biometric
# answer. The Claude hook timeout stays just above this value.
QUESTION_WAIT_SECONDS = 120
MAX_WAIT_SECONDS = 600

APPROVE_ONCE = {
    "id": "approve_once",
    "label": "Allow once",
    "risk": "privileged",
    "requires_foreground": True,
    "requires_biometric": True,
}

# Claude's own third choice is "Yes, don't ask again", which widens a Bash
# command to a prefix rule and saves it per repository. Headroom deliberately
# writes only the exact command or path it was shown: a rule granted from a
# phone outlives the request that prompted it, and a widened prefix grants
# more than the thing you actually looked at. The label says "this exact"
# rather than borrowing Claude's wording, because the two are not the same
# promise.
APPROVE_ALWAYS = {
    "id": "approve_always",
    "label": "Always allow this exact request",
    "risk": "privileged",
    "requires_foreground": True,
    "requires_biometric": True,
}

DECLINE = {"id": "decline", "label": "Deny", "risk": "safe"}

# Deny answers this one request and lets Claude carry on; interrupt stops the
# turn outright. Different enough to be separate answers, and the second is
# destructive.
INTERRUPT = {
    "id": "interrupt",
    "label": "Stop Claude",
    "risk": "destructive",
    "requires_foreground": True,
    "requires_biometric": True,
}

# Claude's own third choice is "No, and tell Claude what to do differently".
# The deny message is read by the model, so a typed reply is a real answer
# rather than a note to yourself — the same channel a chosen option travels on.
REPLY = {
    "id": "reply",
    "label": "Reply",
    "risk": "safe",
    "accepts_text": True,
    "requires_foreground": True,
}

MAX_REPLY_CHARS = 2000

PERMISSION_ACTIONS = [APPROVE_ONCE, DECLINE, REPLY, INTERRUPT]

# Tools whose input names one concrete thing, so an exact-match rule is both
# expressible and meaningful. AskUserQuestion is absent on purpose: "always
# allow this question" is not a grant anybody wants to make.
RULEABLE_TOOLS = {
    "Bash": "command",
    "Edit": "file_path",
    "Write": "file_path",
    "Read": "file_path",
    "NotebookEdit": "notebook_path",
}


def _escape_rule_path(value):
    """Escape the gitignore metacharacters Claude's own rule writer escapes.

    An unescaped `[` in a directory like `[2024-06] Reports` turns a rule for
    one folder into a character class that matches its siblings.
    """
    out = []
    for char in value:
        if char in "[]*?\\":
            out.append("\\")
        out.append(char)
    return "".join(out)


def permission_rule(tool_name, tool_input):
    """The exact-match rule an `approve_always` answer would save, or None."""
    key = RULEABLE_TOOLS.get(tool_name)
    if key is None or not isinstance(tool_input, dict):
        return None
    value = tool_input.get(key)
    if not isinstance(value, str) or not value.strip():
        return None
    value = value.strip()
    if "\n" in value or len(value) > 512:
        return None
    if key == "command":
        return f"{tool_name}({value})"
    return f"{tool_name}({_escape_rule_path(value)})"

PASSIVE_ACTIONS = [
    {"id": "dismiss", "label": "Dismiss", "risk": "safe"},
]

# Answering a question from the phone, without a hook that returns answers.
#
# No Claude Code hook can hand AskUserQuestion a selected option. What a hook
# *can* do is block the call and give Claude a reason, which the docs say is
# "shown to Claude". So a tap sends `deny` with the chosen label as the
# reason, and Claude reads the choice and carries on.
#
# This is a workaround and it shows: Claude sees a blocked tool plus your
# words, not a clean tool result, so it may acknowledge the block or ask
# again. Everything else here exists to keep that honest — one question only,
# a bounded option count, and `defer` the moment we are unsure, which hands
# the question back to the Mac untouched.
CHOICE_PREFIX = "choice_"
MAX_CHOICES = 6
ASK_ON_MAC = {"id": "ask_on_mac", "label": "Ask on Mac", "risk": "safe"}


def _sole_question(tool_input):
    """The one question we can answer with buttons, or None.

    Several questions in one call would need several rounds of taps, and a
    half-answered set is worse than sending it back to the Mac.
    """
    if not isinstance(tool_input, dict):
        return None
    questions = tool_input.get("questions")
    if not isinstance(questions, list) or len(questions) != 1:
        return None
    question = questions[0]
    if not isinstance(question, dict):
        return None
    if question.get("multiSelect"):
        return None
    text = question.get("question")
    if not isinstance(text, str) or not text.strip():
        return None
    options = []
    for option in question.get("options") or []:
        if isinstance(option, dict):
            label = option.get("label")
            description = option.get("description")
        else:
            label, description = option, None
        if not isinstance(label, str) or not label.strip():
            continue
        options.append({
            "label": " ".join(label.split()),
            "description": (
                " ".join(description.split())
                if isinstance(description, str) and description.strip()
                else None
            ),
        })
    if not 2 <= len(options) <= MAX_CHOICES:
        return None
    return {"question": " ".join(text.split()), "options": options}


def _choice_actions(options):
    actions = []
    for index, option in enumerate(options):
        action = {
            "id": f"{CHOICE_PREFIX}{index}",
            "label": option["label"],
            "risk": "safe",
            "requires_foreground": True,
        }
        if option["description"]:
            action["description"] = option["description"]
        actions.append(action)
    return actions + [REPLY, ASK_ON_MAC]


MAX_PROMPT_CHARS = 8000

# `claude -p` runs headless and its hooks are the ones already installed in
# ~/.claude/settings.json, so a session Headroom starts reports to Headroom
# without any extra wiring. `manual` keeps permission requests coming — the
# whole point is that they arrive on your phone.
CLAUDE_TASK_MODE = "manual"


def _claude_binary():
    """Find `claude` without assuming an interactive shell's PATH.

    The host is a LaunchAgent, so its PATH is narrow — the same trap the Codex
    adapter documents.
    """
    configured = shutil.which("claude")
    if configured:
        return configured
    for candidate in (
        os.path.expanduser("~/.claude/local/claude"),
        os.path.expanduser("~/.local/bin/claude"),
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ):
        if os.access(candidate, os.X_OK):
            return candidate
    return None


def _reply_text(value):
    """Typed words, normalised and bounded, or None if there are none."""
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    return text[:MAX_REPLY_CHARS]


def _short(value, fallback, limit=240):
    text = str(value or "").strip() or fallback
    return text if len(text) <= limit else text[:limit - 1] + "…"


def _project(cwd):
    value = str(cwd or "").rstrip("/")
    return os.path.basename(value) or "Claude Code"


def _reasons(payload):
    """Why Claude is asking, from whichever key this version sends.

    `permission_reasons` is the documented field. Older builds sent
    `permission_suggestions`; reading both costs nothing and losing the
    explanation costs the user the only context they get.
    """
    result = []
    for key in ("permission_reasons", "permission_suggestions"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            value = [value]
        if not isinstance(value, list):
            continue
        for entry in value:
            text = entry if isinstance(entry, str) else _render_reason(entry)
            text = " ".join(str(text or "").split())
            if text and text not in result:
                result.append(text)
    return result[:8]


def _render_reason(entry):
    if isinstance(entry, dict):
        for key in ("reason", "message", "description", "rule", "title"):
            value = entry.get(key)
            if isinstance(value, str) and value.strip():
                return value
    return ""


def _answered(question, answer):
    """A phone answer, blocking the call and handing the words to the model."""
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                "The user answered from Headroom on their iPhone instead of "
                f"the terminal. Their answer to \"{question}\" is: {answer}. "
                "Treat this as their reply and continue — do not ask again."
            ),
        },
    }


def _defer():
    """No opinion, said the safest way there is: say nothing.

    An empty body is unambiguously "this hook has no decision" in every
    version of the hook contract. An explicit `permissionDecision` value is
    only as safe as our reading of the enum, and a wrong guess there does not
    degrade — it breaks the tool call.
    """
    return {}


class _PendingPermission:
    def __init__(self):
        self.ready = threading.Event()
        self.action = None
        self.text = None


class ClaudeCodeHooks:
    def __init__(self, store):
        self.store = store
        self._lock = threading.Lock()
        self._pending = {}

    def capabilities(self):
        try:
            hook_status = claude_hooks.inspect()
            enabled = bool(hook_status["installed_events"])
            connection = "ready" if enabled else "disabled"
            error = None
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            enabled = False
            connection = "disconnected"
            error = str(exc)
        return {
            "provider": PROVIDER,
            "adapter": ADAPTER,
            "session_ownership": "external_hook",
            "enabled": enabled,
            "available": True,
            "connection": connection,
            "error": error,
            "version": None,
            "capabilities": {
                "command_approval": {
                    "supported": True, "maturity": "stable"},
                "file_approval": {
                    "supported": True, "maturity": "stable"},
                "permission_grant": {
                    "supported": True, "maturity": "stable"},
                # Answered through the PreToolUse deny channel rather than a
                # real answer API, so it stays experimental on purpose.
                "structured_question": {
                    "supported": True, "maturity": "experimental"},
                "send_message": {
                    "supported": False, "maturity": "planned"},
                "interrupt": {
                    "supported": True, "maturity": "stable"},
            },
        }

    def stop(self):
        with self._lock:
            pending = list(self._pending.items())
            self._pending.clear()
        for event_id, waiter in pending:
            self.store.mark_orphaned(event_id, "Headroom host stopped")
            waiter.ready.set()

    def permission_request(self, payload, wait_seconds=DEFAULT_WAIT_SECONDS):
        """Create an event and wait for its exact allow/deny response.

        Returning None means "no hook decision": Claude falls back to its
        ordinary local permission dialog.
        """
        session_id = payload.get("session_id")
        tool_name = payload.get("tool_name")
        tool_input = payload.get("tool_input")
        if not isinstance(session_id, str) or not session_id.strip():
            raise agent_events.InvalidEvent("Claude session_id is required")
        if not isinstance(tool_name, str) or not tool_name.strip():
            raise agent_events.InvalidEvent("Claude tool_name is required")
        if not isinstance(tool_input, dict):
            raise agent_events.InvalidEvent("Claude tool_input must be an object")
        # AskUserQuestion arrives here too, but it is a question, not a
        # request for permission. Rendered as one it offers Allow or Deny for
        # a choice — answers that mean nothing — so questions are left to the
        # question hook, which knows how to draw them.
        if tool_name == "AskUserQuestion":
            return None
        wait_seconds = max(1, min(MAX_WAIT_SECONDS, int(wait_seconds)))
        provider_request_id = "permission-" + uuid.uuid4().hex
        cwd = payload.get("cwd")
        rule = permission_rule(tool_name, tool_input)
        actions = (
            [APPROVE_ONCE, APPROVE_ALWAYS, DECLINE, REPLY, INTERRUPT] if rule
            else PERMISSION_ACTIONS
        )
        with self._lock:
            event = self.store.create(
                provider=PROVIDER,
                adapter=ADAPTER,
                provider_request_id=provider_request_id,
                session_id=session_id,
                kind="permission_approval",
                title=_project(cwd),
                summary=agent_request.summary(tool_input, tool_name),
                actions=actions,
                detail={
                    "tool_name": tool_name,
                    "request": agent_request.fields(tool_input, tool_name),
                    "reasons": _reasons(payload),
                    "permission_rule": rule,
                    "cwd": cwd,
                    "transcript_path": payload.get("transcript_path"),
                    "permission_mode": payload.get("permission_mode"),
                    "tool_use_id": payload.get("tool_use_id"),
                    "prompt_id": payload.get("prompt_id"),
                },
                expires_at_ms=int((time.time() + wait_seconds) * 1000),
            )
            waiter = _PendingPermission()
            self._pending[event["id"]] = waiter
        waiter.ready.wait(wait_seconds)
        with self._lock:
            self._pending.pop(event["id"], None)
        if waiter.action is None:
            self.store.expire(event["id"], "Claude permission hook timed out")
            return None
        if waiter.action in ("approve_once", "approve_always"):
            self.store.resolve(event["id"], {"action": waiter.action})
            decision = {"behavior": "allow"}
            if waiter.action == "approve_always":
                # Re-derive rather than trusting the stored string: the rule is
                # what Claude will persist, so it comes from the request this
                # process received, not from anything that made a round trip.
                rule = permission_rule(tool_name, tool_input)
                if rule:
                    decision["updatedPermissions"] = [
                        {"rule": rule, "mode": "allow"},
                    ]
            return {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": decision,
                },
            }
        decision = {"behavior": "deny", "message": "Denied from Headroom"}
        if waiter.action == REPLY["id"] and waiter.text:
            self.store.resolve(
                event["id"], {"action": waiter.action, "reply": waiter.text})
            return {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {
                        "behavior": "deny",
                        # Read by the model, so it is written for the model.
                        "message": (
                            "The user replied from Headroom on their iPhone "
                            f"instead of the terminal: {waiter.text}"
                        ),
                    },
                },
            }
        if waiter.action == INTERRUPT["id"]:
            # Stops the turn rather than just this call, so the message has to
            # say a person did it — a bare denial reads as a refusal.
            decision["interrupt"] = True
            decision["message"] = "Stopped from Headroom on your iPhone"
        return {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": decision,
            },
        }

    def question_request(self, payload, wait_seconds=QUESTION_WAIT_SECONDS,
                         mode="notify"):
        """Offer a question's own options as answers, via the deny channel.

        Returns `defer` for anything we cannot answer cleanly, which is the
        documented way to say "no opinion" and hands the question straight
        back to the Mac.
        """
        session_id = payload.get("session_id")
        tool_input = payload.get("tool_input")
        if not isinstance(session_id, str) or not session_id.strip():
            raise agent_events.InvalidEvent("Claude session_id is required")
        if mode != "answer":
            self._question_notice(payload, tool_input)
            return _defer()
        question = _sole_question(tool_input)
        if question is None:
            # Not answerable from here, but still worth seeing there.
            self._question_notice(payload, tool_input)
            return _defer()
        wait_seconds = max(1, min(MAX_WAIT_SECONDS, int(wait_seconds)))
        cwd = payload.get("cwd")
        with self._lock:
            event = self.store.create(
                provider=PROVIDER,
                adapter=ADAPTER,
                provider_request_id="question-" + uuid.uuid4().hex,
                session_id=session_id,
                kind="structured_question",
                title=_project(cwd),
                summary=_short(question["question"], "Claude asked a question"),
                actions=_choice_actions(question["options"]),
                detail={
                    "tool_name": "AskUserQuestion",
                    # No request block: the summary is the question and the
                    # actions carry the options with their reasons, so a
                    # request field here would print all of it a second time.
                    "request": [],
                    "cwd": cwd,
                    "transcript_path": payload.get("transcript_path"),
                    "tool_use_id": payload.get("tool_use_id"),
                },
                expires_at_ms=int((time.time() + wait_seconds) * 1000),
            )
            waiter = _PendingPermission()
            self._pending[event["id"]] = waiter
        waiter.ready.wait(wait_seconds)
        with self._lock:
            self._pending.pop(event["id"], None)
        action = waiter.action
        if action is None:
            self.store.expire(event["id"], "Claude question hook timed out")
            return _defer()
        if action == REPLY["id"] and waiter.text:
            self.store.resolve(
                event["id"], {"action": action, "reply": waiter.text})
            return _answered(question["question"], waiter.text)
        if not action.startswith(CHOICE_PREFIX):
            self.store.resolve(event["id"], {"action": action})
            return _defer()
        try:
            label = question["options"][int(action[len(CHOICE_PREFIX):])]["label"]
        except (ValueError, IndexError):
            self.store.resolve(event["id"], {"action": action})
            return _defer()
        self.store.resolve(event["id"], {"action": action, "answer": label})
        return {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                # Read by the model, so it is written for the model: state the
                # answer, and say it came from the phone rather than letting a
                # blocked tool look like a refusal.
                "permissionDecisionReason": (
                    f"The user answered from Headroom on their iPhone instead "
                    f"of the terminal. Their answer to "
                    f"\"{question['question']}\" is: {label}. "
                    f"Treat this as their reply and continue — do not ask again."
                ),
            },
        }

    def start_task(self, cwd, prompt):
        """Run `claude -p` in a folder, headless, and let the hooks report it.

        Claude Code has no "start a session" API, but it does not need one:
        the hooks Headroom installed are global, so a session started here
        reports to Headroom exactly like one started in a terminal. The
        process is detached on purpose — a turn can run for minutes and the
        HTTP request that started it must not wait for the answer.
        """
        folder = os.path.expanduser(str(cwd or "").strip())
        words = str(prompt or "").strip()
        if not folder or not os.path.isdir(folder):
            raise ValueError("a task needs a folder that exists")
        if not words:
            raise ValueError("a task needs a prompt")
        binary = _claude_binary()
        if binary is None:
            raise RuntimeError("Claude Code executable not found")
        status = claude_hooks.inspect()
        if not status.get("installed"):
            raise RuntimeError(
                "Install Claude hooks first, or the task cannot report back")
        process = subprocess.Popen(
            [binary, "-p", words[:MAX_PROMPT_CHARS],
             "--permission-mode", CLAUDE_TASK_MODE],
            cwd=folder,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        return {"pid": process.pid, "cwd": folder}

    def lifecycle_event(self, payload):
        session_id = payload.get("session_id")
        hook = payload.get("hook_event_name")
        if not isinstance(session_id, str) or not session_id.strip():
            raise agent_events.InvalidEvent("Claude session_id is required")
        if not isinstance(hook, str) or not hook.strip():
            raise agent_events.InvalidEvent(
                "Claude hook_event_name is required")
        if hook in ("UserPromptSubmit", "SessionEnd"):
            self.store.resolve_session(
                PROVIDER, ADAPTER, session_id,
                {"reason": hook},
            )
            return None
        if hook == "Stop":
            tasks = payload.get("background_tasks")
            if isinstance(tasks, list) and any(
                    isinstance(task, dict)
                    and str(task.get("status", "")).lower()
                    not in ("completed", "failed", "cancelled")
                    for task in tasks):
                return None
            return self._passive(
                payload, "agent_waiting",
                "Ready for your next instruction",
            )
        if hook != "Notification":
            return None
        notification_type = str(payload.get("notification_type") or "")
        # PermissionRequest carries the actual command and response channel.
        if notification_type == "permission_prompt":
            return None
        if notification_type == "idle_prompt":
            kind = "agent_waiting"
        elif notification_type == "elicitation_dialog":
            kind = "structured_question"
        else:
            return None
        return self._passive(
            payload, kind,
            _short(payload.get("message"), "Open Claude Code to continue"),
        )

    def _question_notice(self, payload, tool_input):
        """Show the question without holding it.

        Every question, whatever its shape — several at once, multi-select,
        anything. It is read-only by construction: the only way to answer
        remotely is to block the call, and blocking is exactly what this mode
        exists to avoid. You answer where Claude already asked you.
        """
        questions = (tool_input or {}).get("questions")
        if not isinstance(questions, list) or not questions:
            return None
        first = next(
            (q.get("question") for q in questions
             if isinstance(q, dict) and isinstance(q.get("question"), str)
             and q.get("question").strip()),
            None,
        )
        if not first:
            return None
        session_id = payload["session_id"]
        self.store.supersede(
            PROVIDER, ADAPTER, session_id, "structured_question")
        return self.store.create(
            provider=PROVIDER,
            adapter=ADAPTER,
            provider_request_id="question-" + uuid.uuid4().hex,
            session_id=session_id,
            kind="structured_question",
            title=_project(payload.get("cwd")),
            summary=_short(" ".join(first.split()), "Claude asked a question"),
            actions=PASSIVE_ACTIONS,
            detail={
                "tool_name": "AskUserQuestion",
                "request": agent_request.fields(tool_input, "AskUserQuestion"),
                "answer_on_mac": True,
                "cwd": payload.get("cwd"),
            },
            expires_at_ms=agent_events.passive_expires_at_ms(),
        )

    def _passive(self, payload, kind, summary):
        # One row per session per kind: the newest notice replaces the one it
        # makes untrue, instead of stacking behind it.
        self.store.supersede(PROVIDER, ADAPTER, payload["session_id"], kind)
        return self.store.create(
            provider=PROVIDER,
            adapter=ADAPTER,
            provider_request_id="notice-" + uuid.uuid4().hex,
            session_id=payload["session_id"],
            kind=kind,
            # The repository is the stable identity; the summary says what
            # the repository needs from the person.
            title=_project(payload.get("cwd")),
            summary=summary,
            actions=PASSIVE_ACTIONS,
            detail={
                "cwd": payload.get("cwd"),
                "transcript_path": payload.get("transcript_path"),
                "notification_type": payload.get("notification_type"),
                "message": payload.get("message"),
            },
            expires_at_ms=agent_events.passive_expires_at_ms(),
        )

    def respond(self, event, action_id, text=None):
        if action_id == "dismiss":
            self.store.resolve(event["id"], {"action": action_id})
            return
        if (action_id not in (
                "approve_once", "approve_always", "decline",
                REPLY["id"], INTERRUPT["id"], ASK_ON_MAC["id"])
                and not action_id.startswith(CHOICE_PREFIX)):
            raise ValueError("unsupported Claude action")
        if action_id == REPLY["id"] and not _reply_text(text):
            raise ValueError("a reply needs words")
        with self._lock:
            waiter = self._pending.get(event["id"])
            if waiter is None:
                raise RuntimeError("Claude request is no longer pending")
            waiter.action = action_id
            waiter.text = _reply_text(text)
            waiter.ready.set()
