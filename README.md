# headroom

A desk gadget that shows Claude / Codex / Cursor quota + spend, Vercel
builds, git activity, GitHub Actions, Supabase health, and local servers on a
Waveshare **ESP32-S3-Touch-AMOLED-1.8** (368×448), with a matching macOS menu-bar
app. Everything hangs off one local Python host.

```
  ~/.claude JSONL + OAuth          Mac (Python, stdlib)           Clients
  ~/.codex + Cursor state.vscdb    ┌──────────────────┐          ┌──────────────┐
  Vercel CLI / git / gh / SB  ───▶│ headroom_        │◀── HTTP ─│ ESP32 /usage │
  ~/.headroom/{config,sources}    │ server.py :8737  │◀── USB ──│  (Wi‑Fi|CDC) │
                                  │ + usb_bridge     │── HTTP ─▶│ HeadroomBar  │
                                  └──────────────────┘          └──────────────┘
```

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

### Personal config

Copy defaults and edit:

```
cp host/config.example.json ~/.headroom/config.json
```

| Key | Purpose |
|---|---|
| `timezone` | Local day boundary for burn + timestamps |
| `dev_root` | Where git / GitHub repo discovery walks |
| `git_authors` | `git log --author` patterns |
| `vercel_team_slugs` | Preferred Vercel team (else CLI current team) |
| `github_org_prefix` | Org filter for discovered Actions repos |
| `github_always_repos` | Always-watched `owner/name` list |
| `github_max_discovered` | Cap on auto-discovered org repos |

Source toggles live in `~/.headroom/sources.json` (also editable from Mac
Settings). Optional repo extras: `~/.headroom/github.json` →
`{"repos":["owner/name"]}`.

### Modules

| Module | Source |
|---|---|
| `oauth_usage.py` | Keychain `Claude Code-credentials` → Anthropic OAuth usage |
| `codex_usage.py` | `~/.codex/auth.json` → `wham/usage` + reset credits + spend |
| `cursor_usage.py` | Cursor `state.vscdb` → `GetCurrentPeriodUsage` (Auto/API + $) |
| `vercel_builds.py` | Vercel CLI auth → team deployments |
| `git_activity.py` | Commits under configured `dev_root` |
| `github_actions.py` | Failed / running Actions (`HEADROOM_GITHUB_TOKEN` / Keychain / `gh`) |
| `local_servers.py` | `lsof` TCP LISTEN → labeled local dev servers |
| `supabase_usage.py` | Project health via Supabase PAT |
| `daily_burn.py` | Per-day %-point burn across Claude / Codex / Cursor |
| `sources_config.py` | Enabled-source flags for host + ESP32 |
| `app_config.py` | Personal paths / TZ / org filters |

Claude cost is token *value* from `pricing.py` (list rates). Codex spend comes
from ChatGPT `spend_control`; Cursor spend from `planUsage` (+ on-demand
limit). Failures keep the last-good snapshot (`cache_util.keep_stale`).

### Endpoints

| Path | Notes |
|---|---|
| `GET /usage` | Flat JSON for ESP32 + menu bar |
| `GET /health` | Uptime + compact source status |
| `POST /sync/refresh` | Force-refresh sources (LAN OK — ESP32 long-press) |
| `POST /sources` | Toggle enabled sources (loopback) |
| `POST /supabase/refresh` | Force Supabase poll (loopback) |
| `POST /local/stop` | Stop a local server by pid/port (loopback) |

### `/usage` shape (abridged)

```json
{
  "updated": "2026-07-23T22:00:00+0200",
  "plan": "Max 5x",
  "quota_ok": true,
  "session_pct": 42.0,
  "week_pct": 63.0,
  "today": { "total": 1234, "cost_usd": 4.25 },
  "by_day": [
    {"date": "2026-07-22", "claude": 2.0, "codex": 1.5, "cursor": 0.5, "total": 4.0}
  ],
  "codex": {
    "ok": true, "plan": "Team",
    "week_pct": 72.0, "pace_label": "12% in deficit",
    "cost_usd": 120.5, "cost_limit_usd": 500.0, "cost_label": "$120 / $500"
  },
  "cursor": {
    "ok": true, "plan": "Pro",
    "total_pct": 4.4, "auto_pct": 0.0, "api_pct": 33.7,
    "cost_usd": 15.15, "cost_limit_usd": 20.0, "cost_label": "$15 / $20",
    "on_demand_label": "$30 / $30 on-demand"
  },
  "attention": {
    "level": "warn",
    "score": 25,
    "summary": "1 Supabase alert",
    "reasons": [{"level": "warn", "kind": "supabase", "summary": "1 Supabase alert"}]
  },
  "vercel": { "ok": true, "team": "ev-io", "deployments": [] },
  "git": { "ok": true, "commits": [] },
  "github": { "ok": true, "fail_count": 0, "running_count": 1, "runs": [] },
  "supabase": { "ok": true, "alert_count": 0, "projects": [] },
  "activity": [],
  "local": { "ok": true, "servers": [] },
  "sources": [{ "id": "claude", "enabled": true, "ok": true }]
}
```

`attention.level` is `ok` | `warn` | `critical` — the menu-bar icon lights an
amber/red pip when it isn’t `ok`.

## Firmware (ESP32-S3)

1. `cp firmware/src/config_example.h firmware/src/config.h` and fill in your
   Wi-Fi SSID/password and the Mac's LAN IP (`ipconfig getifaddr en0`), or set
   `HOST_NAME` for mDNS.
2. Flash with PlatformIO: `cd firmware && pio run -t upload && pio device monitor`.

The board polls `GET /usage` over Wi‑Fi first. If Wi‑Fi is down or HTTP fails,
it falls back to USB CDC on the same cable used for power/flash — the host
speaks a tiny `HR` framed protocol on `/dev/cu.usbmodem*` (no second daemon).
Travel options: plug into the Mac **or** tether both to a phone hotspot (add
the hotspot SSID in `WIFI_NETWORKS`). Hotel Wi‑Fi often blocks mDNS / client
isolation. `pio device monitor` and the USB bridge cannot share the port; stop
the monitor when you want cable-only data.

**Tap a Headroom grid slot** to open that detail page; tap again (or BOOT) to
return home. **Long-press glance home (~400ms)** force-syncs the host via
`POST /sync/refresh` (same as Mac Settings → Refresh all; works over USB too).
Footer dots mirror `sources[]` health.

Board specifics are in `firmware/src/pin_config.h`. The display is an SH8601
AMOLED over QSPI; the AXP2101 PMU and a TCA9554 expander must be brought up
before the panel turns on — `main.cpp` does this itself over one I2C bus to
avoid the known `Wire.begin()` conflict.

**If the screen stays black:** try `TCA9554_ADDR` = `0x21` in `pin_config.h`
(some board revisions strap the expander there), and confirm the panel powers
via USB.

## macOS menu bar

`macos/` is a native accessory app (**Headroom**) on the same `/usage` feed.

- Status item: three thin quota bars (Claude, Codex, Cursor), plus a
  colored warning pip when `attention` is warn/critical.
- Overview: quota rings, daily burn, attention + spend strip.
- Provider tabs: detailed meters, then activity / Supabase / local servers.
- Settings: backend URL, per-source toggles + refresh, Supabase/GitHub tokens.

See [`macos/README.md`](macos/README.md) for build and run instructions.
