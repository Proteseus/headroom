# headroom

A desk gadget that shows Claude / Codex / Cursor quota, Vercel builds, and
recent git commits on a Waveshare **ESP32-S3-Touch-AMOLED-1.8** (368×448).
Headroom home shows at-a-glance rings + columns; tap a slot for detail, tap
again to go home.

```
  ~/.claude/projects/**/*.jsonl        Mac (Python, stdlib)         ESP32-S3 (Wi-Fi)
  ┌───────────────────────────┐        ┌──────────────────┐        ┌──────────────┐
  │ Claude + Codex + Cursor    │──────▶│ headroom_        │◀──────│ polls /usage │
  │ Vercel CLI → team deploys  │ parse │ server.py :8737  │  HTTP  │ tap to open  │
  │ ~/Dev git + local listeners│──────▶│  GET /usage JSON │  60s   │              │
  └───────────────────────────┘        └──────────────────┘        └──────────────┘
```

The Mac parses Claude Code usage logs for local cost, polls Anthropic's OAuth
`/api/oauth/usage` for Claude Session/Weekly %, OpenAI's
`chatgpt.com/backend-api/wham/usage` (+ reset-credits) for Codex, and Cursor's
`GetCurrentPeriodUsage` (Auto + API pools) via the signed-in IDE token. It also
reads the Vercel CLI login for team deployments (prefers **ev-io** / Envisioning)
and scans `~/Dev` for your recent commits. No extra API keys: Claude reuses
Keychain login, Codex reuses `~/.codex/auth.json`, Cursor reuses
`state.vscdb`, Vercel reuses `~/Library/Application Support/com.vercel.cli/`.

## Host (Mac)

```
cd host
python3 headroom_server.py            # serves http://0.0.0.0:8737/usage
curl -s localhost:8737/usage | python3 -m json.tool
```

Run it on boot with the included launch agent:

```
cp host/com.mz.headroom.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mz.headroom.plist
# restart after host changes:
launchctl kickstart -k gui/$(id -u)/com.mz.headroom
```

Cost is computed from `host/pricing.py` (per-1M rates + cache read/write
multipliers). These are list prices; on a Max plan they represent token
*value*, not out-of-pocket spend. Edit that file if your rates differ.

| Module | Source |
|---|---|
| `host/oauth_usage.py` | Keychain `Claude Code-credentials` → Anthropic OAuth usage |
| `host/codex_usage.py` | `~/.codex/auth.json` → `wham/usage` + limit-reset credits |
| `host/cursor_usage.py` | Cursor `state.vscdb` → `GetCurrentPeriodUsage` (Auto + API) |
| `host/vercel_builds.py` | Vercel CLI auth → team deployments (`ev-io`) |
| `host/git_activity.py` | `~/Dev/*` (+ nested, e.g. `envisioning/*`) `git log` for your authors |
| `host/local_servers.py` | `lsof` TCP LISTEN → labeled local dev servers |

If Claude OAuth fails, the display falls back to dollar rollups. If Codex or
Cursor auth is missing, that page shows “quota unavailable”. Vercel refreshes
the CLI token when expired; if login is missing, the Vercel page shows
unavailable.

### `/usage` shape

```json
{
  "updated": "2026-07-21T14:37:20+0200",
  "plan": "Max 5x",
  "quota_ok": true,
  "session_pct": 100.0,
  "session_pace_pct": 42.0,
  "session_resets_in": "1h 44m",
  "week_pct": 63.0,
  "week_pace_pct": 50.0,
  "week_resets_in": "4d 44m",
  "today":      { "input":.., "output":.., "cache_read":.., "cache_write":.., "total":.., "cost_usd":.. },
  "session_5h": { ... },
  "last_hour":  { ... },
  "week":       { ... },
  "by_model":   { "claude-opus-4-8": { ... } },
  "codex": {
    "ok": true,
    "plan": "Team",
    "week_pct": 96.0,
    "week_pace_pct": 46.2,
    "week_resets_in": "3d 18h",
    "pace_label": "50% in deficit",
    "runs_out_in": "3h 14m",
    "reset_credits_available": 2,
    "reset_credits_expiries": ["10d 7h", "22d 4h"]
  },
  "cursor": {
    "ok": true,
    "plan": "Pro",
    "auto_pct": 0.0,
    "auto_pace_pct": 70.5,
    "api_pct": 33.7,
    "api_pace_pct": 70.5,
    "resets_in": "8d 20h",
    "pace_label": "37% in reserve",
    "on_demand_label": "$30 / $30 on-demand"
  },
  "vercel": {
    "ok": true,
    "team": "ev-io",
    "deployments": [
      {"project": "signals-ai", "state": "READY", "status": "ready",
       "target": "production", "ago": "12m", "branch": "main"}
    ]
  },
  "git": {
    "ok": true,
    "commits": [
      {"repo": "septena-cloud", "subject": "fix auth redirect",
       "ago": "2h", "branch": "main"}
    ]
  }
}
```

## Firmware (ESP32-S3)

1. `cp firmware/src/config_example.h firmware/src/config.h` and fill in your
   Wi-Fi SSID/password and the Mac's LAN IP (`ipconfig getifaddr en0`).
2. Flash with PlatformIO: `cd firmware && pio run -t upload && pio device monitor`.

**Tap a Headroom grid slot** to open that detail page; tap again (or BOOT) to
return home. Local shows listening dev servers on the Mac (node, Next, Vite,
Postgres, …). Claude uses terracotta rings; Codex uses OpenAI green; Cursor
uses cool blue; Vercel shows deploy status dots; Git shows recent commit ages;
Local shows one dot per server.

Board specifics are in `firmware/src/pin_config.h`. The display is an SH8601
AMOLED over QSPI; the AXP2101 PMU and a TCA9554 expander must be brought up
before the panel turns on — `main.cpp` does this itself over one I2C bus to
avoid the known `Wire.begin()` conflict (see repo notes in the source).

**If the screen stays black:** try `TCA9554_ADDR` = `0x21` in `pin_config.h`
(some board revisions strap the expander there), and confirm the panel powers
via USB. If your board revision differs, cross-check the pin numbers and the
power-up sequence against Waveshare's official Arduino demo for this exact
board.

## Layout

CodexBar-style on quota pages: percent bars with a white pace tick, reset
timers, and plan tier. Claude bars stay terracotta; Codex stays OpenAI green;
Cursor stays cool blue (even near 100%).

## macOS menu bar

`macos/` contains a native menu-bar companion (**Headroom**) that uses the same
`/usage` backend as the ESP32. Its status item uses CodexBar's thick-primary,
thin-secondary meter treatment for the selected Claude, Codex, or Cursor
provider, while the popover adds reset/pace detail
plus an all-provider ring overview, Vercel deploys, local servers, recent
commits, and today's token value.

See [`macos/README.md`](macos/README.md) for build and run instructions.
