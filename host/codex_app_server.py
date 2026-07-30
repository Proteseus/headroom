"""Supervised Codex App Server adapter for stable approval requests.

The adapter owns live JSON-RPC callbacks while agent_events.EventStore owns
durable presentation state. A process exit deliberately orphans every pending
callback: JSON-RPC request ids cannot be reconstructed safely after restart.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import threading
import time
from collections import deque

import agent_request
import app_config

PROVIDER = "codex"
ADAPTER = "codex-app-server"
MAX_MESSAGE_BYTES = 1024 * 1024

COMMAND_APPROVAL = "item/commandExecution/requestApproval"
FILE_APPROVAL = "item/fileChange/requestApproval"
USER_INPUT = "item/tool/requestUserInput"
REQUEST_RESOLVED = "serverRequest/resolved"
TURN_COMPLETED = "turn/completed"
TURN_INTERRUPT = "turn/interrupt"

# Ends the whole turn rather than answering this one request, so it is
# destructive and stays behind foreground authentication.
INTERRUPT = {
    "id": "interrupt",
    "label": "Stop Codex",
    "risk": "destructive",
    "requires_foreground": True,
    "requires_biometric": True,
}

APPROVAL_ACTIONS = [
    {
        "id": "approve_once",
        "label": "Allow once",
        "risk": "privileged",
        "requires_foreground": True,
        "requires_biometric": True,
    },
    {"id": "decline", "label": "Deny", "risk": "safe"},
    {
        "id": "cancel",
        "label": "Stop task",
        "risk": "destructive",
        "requires_foreground": True,
    },
]

WIRE_DECISIONS = {
    "approve_once": "accept",
    "decline": "decline",
    "cancel": "cancel",
}

CHOICE_PREFIX = "choice_"
MAX_CHOICES = 6
ASK_ON_MAC = {"id": "ask_on_mac", "label": "Ask on Mac", "risk": "safe"}

# ToolRequestUserInputResponse takes an array of arbitrary strings, so words
# typed on the phone are a first-class answer rather than a workaround. The
# question's own `isOther` says whether the tool invited one; it is passed to
# the client as a hint and not enforced, because the wire accepts either.
REPLY = {
    "id": "reply",
    "label": "Reply",
    "risk": "safe",
    "accepts_text": True,
    "requires_foreground": True,
}
MAX_REPLY_CHARS = 2000

# Field order for an approval, so the phone reads it the way a person would.
COMMAND_FIELDS = (
    "command", "cwd", "reason", "commandActions", "networkApprovalContext",
    "proposedExecpolicyAmendment", "proposedNetworkPolicyAmendments",
)
FILE_FIELDS = ("reason", "grantRoot", "cwd")


def _bundled_candidates(binary):
    """Likely Codex installs omitted from a launchd service's narrow PATH."""
    if binary != "codex":
        return []
    return [
        os.path.expanduser("~/.local/bin/codex"),
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        os.path.expanduser(
            "~/Applications/ChatGPT.app/Contents/Resources/codex"),
        "/Applications/Codex.app/Contents/Resources/codex",
        os.path.expanduser(
            "~/Applications/Codex.app/Contents/Resources/codex"),
    ]


def resolve_binary(binary):
    """Return an executable path without assuming an interactive-shell PATH."""
    configured = os.path.expanduser(str(binary or "").strip())
    if not configured:
        return None
    if "/" in configured:
        return configured if os.access(configured, os.X_OK) else None
    found = shutil.which(configured)
    if found:
        return found
    return next(
        (path for path in _bundled_candidates(configured)
         if os.access(path, os.X_OK)),
        None,
    )


def _child_working_directory():
    """A stable cwd that cannot disappear when Headroom.app is replaced."""
    home = os.path.expanduser("~")
    return home if os.path.isdir(home) else "/"


def _request_key(request_id):
    return json.dumps(request_id, separators=(",", ":"), sort_keys=True)


def _reply_text(value):
    """Typed words, normalised and bounded, or None if there are none."""
    if not isinstance(value, str):
        return None
    text = value.strip()
    return text[:MAX_REPLY_CHARS] if text else None


def _short(value, fallback, limit=240):
    text = str(value or "").strip() or fallback
    return text if len(text) <= limit else text[:limit - 1] + "…"


class CodexAppServer:
    def __init__(self, store, binary=None, log=print):
        self.store = store
        self.configured_binary = binary or app_config.codex_binary()
        self.binary = resolve_binary(self.configured_binary)
        self.log = log
        self._lock = threading.Lock()
        self._write_lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = None
        self._process = None
        self._status = "disabled"
        self._error = None
        self._version = None
        self._stderr_tail = deque(maxlen=8)
        self._pending_by_event = {}
        self._event_by_request = {}
        self._request_id = 100

    def capabilities(self):
        available = self.binary is not None
        with self._lock:
            status = self._status
            error = self._error
            version = self._version
        return {
            "provider": PROVIDER,
            "adapter": ADAPTER,
            "session_ownership": "headroom_launched",
            "enabled": app_config.agent_gateway_enabled(),
            "available": available,
            "resolved_binary": self.binary,
            "connection": status,
            "error": error,
            "version": version,
            "capabilities": {
                "command_approval": {
                    "supported": True, "maturity": "stable"},
                "file_approval": {
                    "supported": True, "maturity": "stable"},
                "permission_grant": {
                    "supported": False, "maturity": "planned"},
                # item/tool/requestUserInput is marked EXPERIMENTAL in Codex's
                # own schema, so the maturity here mirrors the provider's.
                "structured_question": {
                    "supported": True, "maturity": "experimental"},
                # turn/steer exists and would carry one, but it needs a text
                # field on the phone and an expectedTurnId precondition.
                "send_message": {
                    "supported": False, "maturity": "planned"},
                "interrupt": {
                    "supported": True, "maturity": "stable"},
            },
        }

    def start(self):
        if not app_config.agent_gateway_enabled():
            # A disabled adapter cannot answer callbacks retained from an
            # earlier host process. Avoid creating the ledger on machines
            # that have never opted in, but close it cleanly when it exists.
            if os.path.exists(self.store.path):
                self.store.orphan_adapter(
                    PROVIDER, ADAPTER, "adapter disabled")
            with self._lock:
                self._status = "disabled"
            return
        if self.binary is None:
            with self._lock:
                self._status = "disconnected"
                self._error = (
                    "Codex executable not found: "
                    f"{self.configured_binary}"
                )
            return
        # JSON-RPC callback ids are process-local. Any open row loaded from a
        # previous host process is history, not something this child can answer.
        self.store.orphan_adapter(PROVIDER, ADAPTER, "host restarted")
        with self._lock:
            if self._thread is not None and self._thread.is_alive():
                return
            self._stop.clear()
            self._status = "starting"
            self._thread = threading.Thread(
                target=self._supervise,
                name="headroom-codex-app-server",
                daemon=True,
            )
            self._thread.start()

    def stop(self):
        self._stop.set()
        with self._lock:
            process = self._process
            thread = self._thread
            was_active = process is not None or (
                thread is not None and thread.is_alive())
        if not was_active:
            return
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
        self.store.orphan_adapter(PROVIDER, ADAPTER, "adapter stopped")
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=3)
        with self._lock:
            self._status = "stopped"
            self._process = None
            self._thread = None
            self._pending_by_event.clear()
            self._event_by_request.clear()

    def respond(self, event, action_id, text=None):
        with self._lock:
            callback = self._pending_by_event.get(event["id"])
            process = self._process
        if process is None or process.poll() is not None:
            raise RuntimeError("Codex App Server is disconnected")

        # Interrupt ends the turn rather than answering the request, so it is
        # a client request of its own and needs no live callback — only the
        # thread and turn the row was already carrying.
        if action_id == INTERRUPT["id"]:
            turn_id = event.get("turn_id")
            if not turn_id:
                raise RuntimeError("Codex event has no turn to interrupt")
            self._request(TURN_INTERRUPT, {
                "threadId": event["session_id"],
                "turnId": turn_id,
            })
            return

        if callback is None:
            raise RuntimeError("Codex request is no longer pending")
        request_id, method = callback[0], callback[1]

        if method == USER_INPUT:
            question_id, labels = callback[2], callback[3]
            if action_id == ASK_ON_MAC["id"]:
                self._decline_question(request_id)
                return
            if action_id == REPLY["id"]:
                reply = _reply_text(text)
                if not reply:
                    raise ValueError("a reply needs words")
                self._send({"id": request_id, "result": {
                    "answers": {question_id: {"answers": [reply]}},
                }})
                return
            if not action_id.startswith(CHOICE_PREFIX):
                raise ValueError("unsupported Codex question action")
            try:
                label = labels[int(action_id[len(CHOICE_PREFIX):])]
            except (ValueError, IndexError):
                raise ValueError("unknown Codex choice")
            self._send({"id": request_id, "result": {
                "answers": {question_id: {"answers": [label]}},
            }})
            return

        decision = WIRE_DECISIONS.get(action_id)
        if decision is None:
            raise ValueError("unsupported Codex approval action")
        self._send({"id": request_id, "result": {"decision": decision}})

    def _request(self, method, params):
        """A client-initiated call. Ids start past the handshake's own id 1."""
        with self._lock:
            self._request_id += 1
            request_id = self._request_id
        self._send({"id": request_id, "method": method, "params": params})
        return request_id

    def ingest_for_test(self, message):
        """Exercise protocol normalization without starting a child process."""
        self._handle(message)

    def _set_status(self, value, error=None):
        with self._lock:
            self._status = value
            self._error = str(error) if error else None

    def _supervise(self):
        delay = 1.0
        while not self._stop.is_set():
            try:
                self._run_once()
                error = "Codex App Server exited"
            except Exception as exc:
                error = str(exc)
                self.log(f"codex app-server error: {exc}", flush=True)
            self._disconnect(error)
            if self._stop.wait(delay):
                break
            delay = min(30.0, delay * 2)

    def _run_once(self):
        assert self.binary is not None
        command = [self.binary, "app-server", "--listen", "stdio://"]
        with self._lock:
            self._stderr_tail.clear()
        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=False,
            bufsize=0,
            cwd=_child_working_directory(),
        )
        with self._lock:
            self._process = process
            self._status = "starting"
            self._error = None
        stderr_thread = threading.Thread(
            target=self._capture_stderr,
            args=(process,),
            name="headroom-codex-app-server-stderr",
            daemon=True,
        )
        stderr_thread.start()
        self._send({
            "method": "initialize",
            "id": 1,
            "params": {
                "clientInfo": {
                    "name": "headroom",
                    "title": "Headroom",
                    "version": "0.1",
                },
            },
        })
        self._send({"method": "initialized", "params": {}})

        assert process.stdout is not None
        while not self._stop.is_set():
            line = process.stdout.readline(MAX_MESSAGE_BYTES + 1)
            if not line:
                break
            if len(line) > MAX_MESSAGE_BYTES:
                raise RuntimeError("Codex App Server message exceeded 1 MiB")
            try:
                message = json.loads(line)
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise RuntimeError(f"invalid Codex App Server JSON: {exc}")
            if not isinstance(message, dict):
                raise RuntimeError("invalid Codex App Server message")
            self._handle(message)
        process.wait(timeout=2)
        stderr_thread.join(timeout=1)
        if process.returncode:
            with self._lock:
                detail = self._stderr_tail[-1] if self._stderr_tail else None
            message = f"Codex App Server exited (status {process.returncode})"
            if detail:
                message += f": {detail}"
            raise RuntimeError(message)

    def _capture_stderr(self, process):
        stream = process.stderr
        if stream is None:
            return
        for line in iter(stream.readline, b""):
            detail = line.decode("utf-8", errors="replace").strip()
            if detail:
                with self._lock:
                    self._stderr_tail.append(detail)

    def _send(self, message):
        payload = (
            json.dumps(message, separators=(",", ":")).encode("utf-8") + b"\n"
        )
        if len(payload) > MAX_MESSAGE_BYTES:
            raise RuntimeError("Codex App Server request exceeded 1 MiB")
        with self._write_lock:
            with self._lock:
                process = self._process
            if process is None or process.stdin is None or process.poll() is not None:
                raise RuntimeError("Codex App Server is disconnected")
            process.stdin.write(payload)
            process.stdin.flush()

    def _handle(self, message):
        if message.get("id") == 1 and "result" in message:
            result = message.get("result") or {}
            with self._lock:
                self._status = "ready"
                self._version = result.get("userAgent")
                self._error = None
            return
        method = message.get("method")
        params = message.get("params")
        if method in (COMMAND_APPROVAL, FILE_APPROVAL) and "id" in message:
            if not isinstance(params, dict):
                self._send({
                    "id": message["id"],
                    "result": {"decision": "decline"},
                })
                return
            self._record_approval(message["id"], method, params)
            return
        if method == USER_INPUT and "id" in message:
            if not isinstance(params, dict):
                self._send({"id": message["id"], "error": {
                    "code": -32602, "message": "invalid params"}})
                return
            self._record_question(message["id"], params)
            return
        if method == REQUEST_RESOLVED and isinstance(params, dict):
            self._resolved(params.get("requestId"))
            return
        if method == TURN_COMPLETED and isinstance(params, dict):
            turn = params.get("turn") or {}
            turn_id = turn.get("id") if isinstance(turn, dict) else None
            if isinstance(turn_id, str) and turn_id:
                self.store.resolve_turn(
                    PROVIDER, ADAPTER, turn_id,
                    {"reason": "turn completed"},
                )

    def _record_approval(self, request_id, method, params):
        session_id = params.get("threadId")
        turn_id = params.get("turnId")
        item_id = params.get("itemId")
        if not all(isinstance(value, str) and value for value in (
                session_id, turn_id, item_id)):
            self._send({
                "id": request_id,
                "result": {"decision": "decline"},
            })
            return
        reason = params.get("reason")
        if method == COMMAND_APPROVAL:
            command = params.get("command")
            title = "Codex needs command approval"
            summary = _short(reason or command, "Run a command")
            fields = {key: params.get(key) for key in COMMAND_FIELDS
                      if params.get(key) is not None}
            detail = {
                "tool_name": "Codex command",
                # Same typed-field contract Claude uses, so one client renders
                # both. commandActions and networkApprovalContext were
                # captured here for a year and never reached a screen.
                "request": agent_request.fields(fields, "CodexCommand"),
                "reason": reason,
                "command": command,
                "cwd": params.get("cwd"),
            }
            kind = "command_approval"
        else:
            title = "Codex needs file approval"
            summary = _short(reason, "Apply proposed file changes")
            fields = {key: params.get(key) for key in FILE_FIELDS
                      if params.get(key) is not None}
            detail = {
                "tool_name": "Codex file change",
                "request": agent_request.fields(fields, "CodexFileChange"),
                "reason": reason,
                "grant_root": params.get("grantRoot"),
            }
            kind = "file_approval"
        key = _request_key(request_id)
        event = self.store.create(
            provider=PROVIDER,
            adapter=ADAPTER,
            provider_request_id=key,
            session_id=session_id,
            turn_id=turn_id,
            item_id=item_id,
            kind=kind,
            title=title,
            summary=summary,
            detail=detail,
            actions=APPROVAL_ACTIONS + [INTERRUPT],
            created_at_ms=params.get("startedAtMs"),
        )
        with self._lock:
            self._pending_by_event[event["id"]] = (request_id, method)
            self._event_by_request[key] = event["id"]

    def _record_question(self, request_id, params):
        """One answerable question becomes buttons; anything else is a notice.

        Codex's shape matches Claude's closely enough to share the ledger's
        choice vocabulary, so one phone control answers both.
        """
        session_id = params.get("threadId")
        turn_id = params.get("turnId")
        item_id = params.get("itemId")
        questions = params.get("questions")
        if not isinstance(questions, list) or len(questions) != 1 or not all(
                isinstance(value, str) and value
                for value in (session_id, turn_id, item_id)):
            self._decline_question(request_id)
            return
        question = questions[0]
        if not isinstance(question, dict):
            self._decline_question(request_id)
            return
        # A secret never leaves the Mac and is never typed on a phone.
        if question.get("isSecret"):
            self._decline_question(request_id)
            return
        text = question.get("question")
        question_id = question.get("id")
        if not all(isinstance(value, str) and value.strip()
                   for value in (text, question_id)):
            self._decline_question(request_id)
            return
        options = []
        for option in question.get("options") or []:
            if not isinstance(option, dict):
                continue
            label = option.get("label")
            if isinstance(label, str) and label.strip():
                options.append({
                    "label": " ".join(label.split()),
                    "description": (
                        " ".join(str(option.get("description")).split())
                        if isinstance(option.get("description"), str)
                        and option["description"].strip() else None
                    ),
                })
        if not 2 <= len(options) <= MAX_CHOICES:
            self._decline_question(request_id)
            return
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
        key = _request_key(request_id)
        event = self.store.create(
            provider=PROVIDER,
            adapter=ADAPTER,
            provider_request_id=key,
            session_id=session_id,
            turn_id=turn_id,
            item_id=item_id,
            kind="structured_question",
            title=f"Codex is asking you: {_short(question.get('header'), 'a question', 60)}",
            summary=_short(" ".join(text.split()), "Codex asked a question"),
            # The summary is the question and the actions are the options, so
            # a request block would print all of it a second time.
            detail={"tool_name": "Codex question", "request": []},
            actions=actions + [REPLY, ASK_ON_MAC, INTERRUPT],
        )
        with self._lock:
            self._pending_by_event[event["id"]] = (
                request_id, USER_INPUT, question_id,
                [option["label"] for option in options],
            )
            self._event_by_request[key] = event["id"]

    def _decline_question(self, request_id):
        """No opinion: an empty answer set leaves the question to the Mac."""
        self._send({"id": request_id, "result": {"answers": {}}})

    def _resolved(self, request_id):
        key = _request_key(request_id)
        with self._lock:
            event_id = self._event_by_request.pop(key, None)
            if event_id is not None:
                self._pending_by_event.pop(event_id, None)
        if event_id is not None:
            self.store.resolve(event_id, {"reason": "provider resolved"})

    def _disconnect(self, error):
        self.store.orphan_adapter(PROVIDER, ADAPTER, error)
        with self._lock:
            process = self._process
            self._process = None
            self._status = "disconnected"
            self._error = str(error)
            self._pending_by_event.clear()
            self._event_by_request.clear()
        if process is not None and process.poll() is None:
            process.terminate()
