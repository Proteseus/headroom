# Headroom

**Your AI coding quotas and ship status — on the desk and in the menu bar.**

When you're deep in Claude, Codex, or Cursor, you shouldn't have to dig through
billing pages, `gh`, and Vercel to answer: *Am I about to hit a limit? Did CI
go red? Is prod healthy?*

Headroom is a **local-first** desk gadget + macOS menu bar that consolidates
that into one glance:

| Always on | What you see |
|---|---|
| **ESP32 AMOLED** | Claude / Codex / Cursor quota rings, Vercel, git, local ports |
| **Menu bar** | Three thin remaining-quota meters + amber/red attention pip |
| **Popover** | Overview rings, daily burn, spend, Actions / Supabase / servers |

One Python host on your Mac reads local auth + CLIs and serves a single JSON
feed. No cloud account for Headroom itself — your tokens stay on the machine.

<p align="center">
  <img src="docs/screenshots/esp32-glance.png" alt="ESP32 Headroom glance home" width="420" />
</p>

<p align="center">
  <img src="docs/screenshots/macos-menubar.png" alt="macOS menu bar + popover" width="360" />
</p>

```
  ~/.claude JSONL + OAuth          Mac (Python, stdlib)           Clients
  ~/.codex + Cursor state.vscdb    ┌──────────────────┐          ┌──────────────┐
  Vercel CLI / git / gh / SB  ───▶│ headroom_        │◀── HTTP ─│ ESP32 /usage │
  ~/.headroom/{config,sources}    │ server.py :8737  │◀── USB ──│  (Wi‑Fi|CDC) │
                                  │ + usb_bridge     │── HTTP ─▶│ HeadroomBar  │
                                  └──────────────────┘          └──────────────┘
```

**Hardware is optional.** The menu bar alone is useful. The Waveshare
ESP32-S3-Touch-AMOLED-1.8 (368×448) is the always-on desk glance — same feed,
tap a slot for detail, long-press to force-refresh.

## Why it exists

- **Quota anxiety is real.** Session / weekly windows, pace, and spend are
  scattered across three products. Headroom puts hottest pool % + pace on one
  ring (and three menu-bar ticks).
- **Ship status is ambient.** Failed Actions, Vercel builds, Supabase alerts,
  and listening local servers surface as an attention pip — not another tab.
- **Local-first.** The host talks to credentials and CLIs you already have.
  The board can fall back to USB CDC when hotel Wi‑Fi blocks mDNS.

## Quick start

### 1. Host

```bash
cd host
cp config.example.json ~/.headroom/config.json   # edit authors / org / timezone
python3 headroom_server.py                       # http://0.0.0.0:8737/usage
curl -s localhost:8737/usage | python3 -m json.tool
```

Optional login item (edit `REPLACE_WITH_*` paths in the plist first):

```bash
mkdir -p ~/.headroom/logs
cp host/com.mz.headroom.plist ~/Library/LaunchAgents/
# then: launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mz.headroom.plist
```

### 2. Menu bar

```bash
cd macos
xcodegen generate   # if you change project.yml
xcodebuild -project HeadroomBar.xcodeproj -scheme HeadroomBar \
  -configuration Debug -derivedDataPath .build build
open .build/Build/Products/Debug/HeadroomBar.app
```

No Dock icon. Settings live under the popover gear (endpoint, source toggles,
Supabase / GitHub tokens).

### 3. ESP32 (optional)

1. `cp firmware/src/config_example.h firmware/src/config.h` — Wi‑Fi SSIDs +
   Mac hostname (`scutil --get LocalHostName`) or fallback IP.
2. Paste the host token into `HOST_TOKEN` (see below). The host prints it at
   startup and keeps it in `~/.headroom/token`.
3. `cd firmware && pio run -t upload && pio device monitor`

Wi‑Fi first; USB CDC fallback on the same cable when the LAN path fails.
**Tap** a glance slot for detail; **long-press** home (~400ms) →
`POST /sync/refresh`.

After the first cable flash, `OTA_HOSTNAME` is reachable for updates:

```bash
pio run -t upload --upload-port headroom.local
```

The board fetches `GET /usage?view=device` — a ~2KB projection of the full
document holding only what it renders. That matters on the cable: 30KB at
115200 baud is ~2.6s per poll. `host/device_view.py` owns the projection and
its row caps mirror the `MAX_*` constants in `firmware/src/main.cpp`;
`host/test_contract.py` fails if the two drift.

### Access control

`/usage` carries repo names, commit subjects, local server paths and ports, and
spend. The host binds `0.0.0.0` so the board can reach it, which also exposes
that to everyone else on the network — so **non-loopback callers must present a
token**. Loopback (the menu bar, `curl localhost`, the USB bridge) needs
nothing.

The token is generated on first run into `~/.headroom/token` (mode 0600) and
printed at startup. Send it as `X-Headroom-Token:` or `Authorization: Bearer`:

```bash
curl -s -H "X-Headroom-Token: $(cat ~/.headroom/token)" http://mz-mbp.local:8737/usage
```

Override it with `auth_token` in `~/.headroom/config.json`, or set
`"require_auth": false` there to restore the old open-network behaviour.

## What it tracks

| Source | How |
|---|---|
| Claude | Keychain OAuth → Anthropic usage; token *value* via `pricing.py` |
| Codex | `~/.codex/auth.json` → weekly window, pace, reset credits, spend |
| Cursor | `state.vscdb` → Auto / API / total + on-demand |
| Vercel | CLI auth → recent team deployments |
| Git | Commits under `dev_root` matching `git_authors` |
| GitHub Actions | Failed / running runs (`HEADROOM_GITHUB_TOKEN` / Keychain / `gh`) |
| Supabase | Project health via PAT |
| Local servers | `lsof` TCP LISTEN → labeled ports (stop from the menu bar) |
| Daily burn | Per-day %-point burn across Claude / Codex / Cursor |

Toggle sources in `~/.headroom/sources.json` or Mac Settings. Failures keep the
last-good snapshot (`cache_util.keep_stale`).

Each row above is one entry in `SOURCES` in `host/sources_config.py` — id,
title, poll interval, fetcher, and the two formatters. The HTTP payload, the
Settings list, the ESP32 footer dots, and the poll schedule all derive from it,
so adding a source means adding one entry rather than editing four places.

### Tests

```bash
cd host && python3 -m unittest discover -p "test_*.py"
cd macos && xcodegen generate && xcodebuild test -project HeadroomBar.xcodeproj -scheme HeadroomBar -derivedDataPath .build
cd firmware && pio run
```

`host/test_contract.py` and `macos/Tests/ContractTests.swift` pin the `/usage`
shape from both sides — the document is described in Python, in Swift `Codable`
structs, and in C++ field reads, and renaming a key used to break the siblings
silently. CI runs all three on push (`.github/workflows/ci.yml`).

### Personal config (`~/.headroom/config.json`)

| Key | Purpose |
|---|---|
| `timezone` | Local day boundary for burn + timestamps |
| `dev_root` | Where git / GitHub repo discovery walks |
| `git_authors` | `git log --author` patterns (empty = all authors) |
| `vercel_team_slugs` | Preferred Vercel team(s); empty → CLI current team |
| `github_org_prefix` | Org filter for discovered Actions repos |
| `github_always_repos` | Always-watched `owner/name` list |
| `github_max_discovered` | Cap on auto-discovered org repos |
| `auth_token` | Override the generated LAN token |
| `require_auth` | `false` opens `/usage` to the whole network (default `true`) |

### Endpoints

Everything below is loopback-open and token-gated off-box.

| Path | Notes |
|---|---|
| `GET /usage` | Full flat JSON for the menu bar |
| `GET /usage?view=device` | ~2KB projection the ESP32 polls |
| `GET /health` | Uptime + compact source status + cache age |
| `POST /sync/refresh` | Force-refresh (LAN OK — ESP32 long-press) |
| `POST /sources` | Toggle enabled sources (loopback) |
| `POST /supabase/refresh` | Force Supabase poll (loopback) |
| `POST /local/stop` | Stop a local server by pid/port (loopback) |

The served document is rebuilt once per poll tick and cached as bytes, so a GET
is a copy rather than a re-aggregation — three clients poll this.

`attention.level` is `ok` | `warn` | `critical` — the menu-bar icon lights an
amber/red pip when it isn’t `ok`.

## Screenshots

Regenerate README assets from the scrubbed demo fixture:

```bash
./scripts/generate_screenshots.sh
```

- `docs/screenshots/esp32-glance.png` — firmware glance layout (Python preview)
- `docs/screenshots/macos-popover.png` — live SwiftUI export from HeadroomBar
- `docs/screenshots/macos-menubar.png` — menu bar + popover composite

## Board notes

Waveshare **ESP32-S3-Touch-AMOLED-1.8**. SH8601 over QSPI; AXP2101 + TCA9554
must come up before the panel — see `firmware/src/main.cpp` / `pin_config.h`.

**Black screen?** Try `TCA9554_ADDR = 0x21` in `pin_config.h` (some revisions
strap the expander there). `pio device monitor` and the USB bridge cannot share
the port.

## License

MIT — see [LICENSE](LICENSE).
