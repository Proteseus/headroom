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
| **Menu bar** | Thin remaining-quota meters for enabled providers + amber/red attention pip |
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
  scattered across products. Headroom puts hottest pool % + pace on one
  ring (and a menu-bar tick per enabled provider).
- **Ship status is ambient.** Failed Actions, Vercel builds, Supabase alerts,
  and listening local servers surface as an attention pip — not another tab.
- **Local-first.** The host talks to credentials and CLIs you already have.
  The board can fall back to USB CDC when hotel Wi‑Fi blocks mDNS.

## Requirements

| Need | Notes |
|---|---|
| macOS 14+ | Menu bar app |
| Python 3.9+ | Bundled host is **stdlib only** (system `/usr/bin/python3`) |
| At least one of Claude / Codex / Cursor | Already signed in locally |
| Optional: Xcode + [xcodegen](https://github.com/yonaskolb/XcodeGen) | Only if you build from source |
| Optional: PlatformIO | Only if you flash the ESP32 |

No Headroom cloud account. Tokens stay on your Mac.

## Quick start (from scratch)

### Option A — Release app (easiest)

1. Download **HeadroomBar-macos.zip** from
   [Releases](https://github.com/michellzappa/headroom/releases).
2. Unzip and open `HeadroomBar.app` (right-click → Open the first time if
   Gatekeeper complains — builds are ad-hoc signed).
3. Click the menu bar meters → on first launch you’ll get a **Welcome** sheet.
4. Tap **Start host & keep at login** — the app installs a LaunchAgent that runs
   the **Python host bundled inside the .app**.
5. Confirm which providers were detected (Claude / Codex / Cursor) and Continue.

That’s it. The host stays up after you quit the menu bar (ESP32-friendly).

### Option B — Build from source

```bash
git clone https://github.com/michellzappa/headroom.git
cd headroom
./scripts/build-app.sh          # embeds host → dist/HeadroomBar.app
open dist/HeadroomBar.app
```

Or the two-piece flow (host from clone, debug app):

```bash
./scripts/install-host.sh
cd macos && ../scripts/sync-embedded-host.sh && xcodegen generate
xcodebuild -project HeadroomBar.xcodeproj -scheme HeadroomBar \
  -configuration Debug -derivedDataPath .build build
open .build/Build/Products/Debug/HeadroomBar.app
```

**Foreground try** (no login item): `./scripts/install-host.sh --foreground`  
**Uninstall LaunchAgent:** `./scripts/uninstall-host.sh` (`--purge` wipes `~/.headroom`)

### What happens on first run

- `~/.headroom/sources.json` is seeded from **local detection** — only providers
  that look signed-in are enabled. If none are found, all three quota sources
  stay on so the UI can show sign-in errors.
- The Welcome sheet lets you confirm toggles before the overview appears.
- Edit `~/.headroom/config.json` later for git authors / GitHub org / timezone.

```bash
curl -s localhost:8737/health | python3 -m json.tool
curl -s localhost:8737/setup  | python3 -m json.tool
```

### ESP32 desk display (optional)

Hardware is optional. The menu bar alone is useful.

1. `cp firmware/src/config_example.h firmware/src/config.h` — Wi‑Fi SSIDs +
   Mac hostname (`scutil --get LocalHostName`) or fallback IP.
2. Paste the host token into `HOST_TOKEN` (`~/.headroom/token` after first start).
3. `cd firmware && pio run -t upload && pio device monitor`

Wi‑Fi first; USB CDC fallback when LAN fails. **Tap** a glance slot for detail;
**long-press** home → `POST /sync/refresh`.

### Troubleshooting

| Symptom | Fix |
|---|---|
| Welcome / host isn’t running | Tap **Start host & keep at login** in the popover |
| Host unhealthy | `tail -f ~/.headroom/logs/headroom.err` |
| Empty provider | Sign into that app/CLI; enable under Settings → Sources |
| Gatekeeper blocks .app | Right-click → Open (ad-hoc CI builds aren’t notarized yet) |
| Restart host | `launchctl kickstart -k gui/$(id -u)/com.mz.headroom` |
| Build a fresh .app | `./scripts/build-app.sh` → `dist/HeadroomBar.app` |

### Access control

`/usage` carries repo names, commit subjects, local paths/ports, and spend.
The host binds `0.0.0.0` so the board can reach it — **non-loopback callers
must present a token**. Loopback needs nothing.

Token is generated into `~/.headroom/token` (mode 0600). Send
`X-Headroom-Token:` or `Authorization: Bearer`. Override with `auth_token` /
`"require_auth": false` in `~/.headroom/config.json`.

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

Toggle sources in `~/.headroom/sources.json` or Mac Settings — CodexBar-style:
only enabled quota providers appear in the menu bar, overview rings, and tabs.
Firmware still knows the three built-in pages but hides disabled ones. Failures
keep the last-good snapshot (`cache_util.keep_stale`).

Each row above is one entry in `SOURCES` in `host/sources_config.py` — id,
title, poll interval, fetcher, and the two formatters. Quota rows also carry
`kind="quota"`, pool specs, and a burn headline; from that the host derives
sample pools, daily burn, and `/usage` → `providers[]`. The HTTP payload, the
Settings list, the ESP32 footer dots, and the poll schedule all follow the
registry, so adding an activity source is one entry. Adding a coding provider
is one entry + a fetcher module (Mac still maps known ids for meters until the
UI is fully schema-driven).

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
| `GET /setup` | Detected credentials + enabled map (first-run sheet) |
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
