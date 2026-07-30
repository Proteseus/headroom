# Coding-agent attention gateway

Headroom's attention gateway turns provider callbacks into one durable feed.
The feed is provider-neutral; each adapter declares what it can safely send
back. Codex is the first adapter.

This is the **gateway** layer (events ledger + adapters). The separate
**rollup** Attention card / menu-bar pip is product policy, not Settings —
see [`attention.md`](attention.md).

## What exists now

- A SQLite attention ledger with compare-and-swap revisions, idempotency keys,
  expiry, provider resolution, and disconnect/orphan states.
- A supervised Codex App Server process using its JSONL stdio transport.
- Stable Codex command-execution and file-change approval requests normalized
  into the common event shape.
- Managed Claude Code HTTP hooks for permission requests, stop/idle attention,
  elicitation notices, prompt submission, and session end.
- The provider's actual request, field by field, on every client — see
  **Request exposure** below.
- Synchronous Claude permission answers: the hook request waits in a bounded
  host thread, and an iPhone Allow once / Deny response wakes that exact
  request with Claude's documented decision JSON.
- `GET /agents/capabilities`
- `GET /attention/events?state=open&limit=50&after_ms=…`
- `POST /attention/events/{id}/respond`
- A separate `agents` mobile permission. It is off by default, even when the
  ordinary iPhone dashboard permissions use their defaults.
- iPhone feed rows, local notifications, and in-app responses. Privileged
  actions marked `requires_biometric` invoke device-owner authentication.

The gateway itself is opt-in. On the Mac that runs the Headroom host, open
**Headroom Settings → Coding agents**, enable the Codex attention gateway,
choose the Codex executable if `codex` is not on the host's launchd path, and
click **Apply & test**. That test starts `codex app-server`, performs its
protocol handshake, and reports the live adapter version/status. It does not
yet spend tokens or create a test task.

The equivalent config, useful for headless hosts, is:

```json
{
  "agent_gateway_enabled": true,
  "codex_binary": "codex"
}
```

Put those keys in `~/.headroom/config.json` and restart the host. The Mac UI
uses localhost-only `GET` and `POST /agents/config`; this endpoint is
intentionally unavailable over LAN because it controls a local executable.

Claude Code does not require Headroom to launch its sessions. In
**Headroom Settings → Coding agents**, click **Install hooks**. Headroom adds
only marked entries under `~/.claude/settings.json`, preserves every foreign
hook, writes atomically, and keeps `settings.json.bak-headroom`. **Remove
hooks** removes only Headroom-owned entries.

The installed `PermissionRequest` hook posts the complete tool request to the
localhost host and can return Allow or Deny. Lifecycle hooks post finished,
idle, and elicitation attention. A prompt submission or session end resolves
the corresponding passive rows. If the host is unavailable or the permission
wait expires, the hook supplies no decision and Claude falls back to its normal
local permission dialog.

## Deliberate boundary

This Codex App Server instance currently uses Codex's stdio transport and owns
**Headroom-launched sessions**. It cannot attach itself to an unrelated Codex
Desktop, CLI, or IDE process and intercept that process's callbacks. In
particular, an already-running conversation cannot be transparently moved
between App Server processes while a turn is live.

Codex also supports an App Server listening on a local Unix socket, and Codex
CLI can connect to it with `codex --remote unix://PATH`. That is the right next
transport for Headroom: one Headroom-supervised App Server, with Headroom and
future CLI clients subscribing to its tasks. Stored inactive tasks may be
resumed by task ID, but live ownership and approval routing must remain with
the App Server that received the request.

The iPhone currently schedules a local notification when a foreground or
background refresh sees a new event. Guaranteed immediate delivery while the
app is suspended requires APNs registration plus a push provider on the
server; polling alone cannot provide that guarantee.

## Request exposure

An approval you cannot read is not an approval. Adapters no longer paraphrase
the provider's request into one line; they hand the raw request object to
`host/agent_request.py`, which returns an ordered list of typed fields under
`detail.request`:

```json
{
  "key": "old_string",
  "label": "Replacing",
  "kind": "code",
  "value": "const port = 3000",
  "truncated": false,
  "full_chars": 17
}
```

`key` is the provider's own name and `label` is for humans. `kind` is one of
`text`, `command`, `code`, `path`, `json`, `number`, `bool`; a client that meets
an unknown kind draws it as text, so a tool nobody has seen renders without an
app update. Known tools keep the order a person reads them in
(`Edit` is file, before, after); everything else follows sorted, which is what
makes an arbitrary MCP tool legible rather than a special case.

Three rules hold the contract together:

- **Bounds live in the host, not the client.** One `Write` of a large file
  would otherwise land in the SQLite ledger, every `/attention/events`
  response, and every phone that polls it. Per-field, per-request and total
  caps are in `agent_request`; `agent_events.MAX_DETAIL` is the backstop that
  catches an adapter bug rather than trusting one.
- **Clipping is never silent.** `truncated` plus `full_chars` reach the client,
  which says so on screen. Approving a prefix of a command while believing it
  is the whole command is the failure this design exists to prevent.
- **`detail.reasons` is why the provider is asking.** Claude sends
  `permission_reasons`; older builds sent `permission_suggestions`. The adapter
  reads both, because losing the explanation costs the user the only context
  they get.

The raw provider request is deliberately **not** stored. The typed fields carry
both key and value, so nothing downstream needs it — and `updatedInput` merges
per field, so answering never needs the original either.

## Provider capability metadata

Clients must render only actions the provider adapter reports as supported.
`GET /agents/capabilities` returns one record per adapter, including:

```json
{
  "provider": "codex",
  "adapter": "codex-app-server",
  "session_ownership": "headroom_launched",
  "enabled": true,
  "available": true,
  "connection": "ready",
  "capabilities": {
    "command_approval": {"supported": true, "maturity": "stable"},
    "file_approval": {"supported": true, "maturity": "stable"},
    "structured_question": {"supported": false, "maturity": "experimental"},
    "send_message": {"supported": false, "maturity": "planned"},
    "interrupt": {"supported": false, "maturity": "planned"}
  }
}
```

Event actions also carry per-action policy metadata:

- `risk`: `safe`, `privileged`, or `destructive`
- `requires_foreground`
- `requires_biometric`

The server remains authoritative. A stale event revision, reused idempotency
key with a different action, provider-side resolution, or disconnected adapter
returns a conflict instead of sending a second answer.

## Common event lifecycle

```text
provider request
  -> pending
  -> responding
  -> resolved

pending/responding
  -> declined | cancelled | expired | orphaned
```

The SQLite row is durable, but a live JSON-RPC callback is not. If the Codex
process disconnects, open events become `orphaned`; Headroom never guesses that
a request ID from a previous process can still be answered.

## Next slices

1. Replace the private stdio child with a local Unix-socket App Server and a
   Headroom WebSocket subscriber; expose the exact `codex --remote
   unix://PATH` launch command in Settings.
2. Add Headroom-owned Codex task creation, resume/subscription, turn start,
   message, and interrupt routes, storing provider task IDs beside events.
3. Add an explicit end-to-end test task that requests a harmless approval,
   appears on iPhone, and verifies the selected answer reaches Codex.
4. Add an APNs device registry and push worker. Notifications should contain an
   opaque event ID and revision, never credentials or full command text.
5. Register notification categories for safe actions. Keep privileged and
   destructive answers behind foreground authentication unless policy
   explicitly allows otherwise.
6. Add structured questions after Codex promotes that App Server request from
   experimental, or behind an explicitly versioned adapter flag.
7. **Answer Claude's questions and rules.** Verified against Claude Code
   2.1.220, so this is a wiring gap rather than a provider gap:

   | Answer | How | Headroom today |
   |---|---|---|
   | Always allow | `decision.updatedPermissions: [{rule, mode}]` | `permission_grant` still reports `planned` |
   | Form values | `Elicitation` hook returns `action: "accept"` + `content` | neither `Elicitation` nor `ElicitationResult` is installed |
   | Edit before allowing | `decision.updatedInput` (merges per field) | not modelled |
   | Interrupt | `decision.interrupt` | Codex has **Stop task**; Claude has no equivalent |

   The `Elicitation` hook receives `schema` plus `questions[]` (`field`,
   `question`, `type`, `options`, `default`) — the real question, not the
   `Notification` shadow with `notification_type: elicitation_dialog` that
   Headroom listens to now. That shadow carries no schema and accepts no
   answer, which is why questions currently read as notify-only.

   Two transport changes gate all four: `AgentAttentionResponseRequest` carries
   only `{revision, action, idempotency_key}` and needs a payload for form
   `content`, a chosen rule, or an edited input; and the answer path has to stay
   revision-safe, since a rule that outlives the request is a durable grant made
   from a phone.

   `claude_hooks.EVENTS` also omits the documented `agent_needs_input`,
   `agent_completed`, `elicitation_complete` and `elicitation_response`
   notification types.
8. Implement a Cursor adapter against the same ledger. An adapter may be
   display-only; unsupported response capabilities remain visible in metadata
   rather than being inferred by the client.
9. Project the same open feed onto ESP32. The board is a strong ambient signal;
   sending approvals from a two-button device should be limited to actions
   explicitly marked safe.

## What Claude Monitor teaches us

[Claude Monitor](https://github.com/cliq/claude-monitor) is a strong reference
for provider installation and attention-state UX, even though it does not send
answers back to Claude:

- Detect each provider installation and show **Install**, **Installed**,
  **Outdated**, or **Modified externally**, rather than hiding setup in a
  config file.
- Own only clearly marked config entries, write settings atomically, and keep a
  backup. Its Claude hook commands carry managed-by/version markers because
  another JSON serializer may discard unknown metadata.
- Make event hooks fail open. Monitoring must never block the coding agent.
- Normalize noisy provider events into a small state machine such as working,
  background work, waiting, needs attention, finished, and stale.
- Retain provider/session context such as task ID, working directory, PID, and
  terminal so the app can offer **Open on Mac** when remote answering is not
  supported.
- Keep notification policy separate from transport, with an obvious master
  toggle and a real test action.

Headroom should copy those lifecycle and resilience patterns. Its differentiator
is the durable event ledger plus capability-checked, revision-safe response
path; provider adapters must never pretend they can answer when they can only
notify or focus the original terminal.
