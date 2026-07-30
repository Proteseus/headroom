# Working on Headroom

Conventions and traps for anyone — human or agent — changing this repo.
Several agents often work here at once, which is what most of this is about.

## Build

XcodeGen owns the project. Never hand-edit `macos/Headroom.xcodeproj`; edit
`macos/project.yml` and regenerate. Always go through the script, which syncs
the embedded host first (bare `xcodegen generate` fails on a fresh clone):

```bash
./scripts/gen-project.sh
```

Anything touching watchOS — including the iPhone app, which embeds the watch
app — needs the beta toolchain on this Mac. The default Xcode reports a watchOS
SDK and even has it on disk, but resolves every destination to *"watchOS 26.5
is not installed"*:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
```

Do not pass `-sdk iphonesimulator` to the iOS build under the beta. It
overrides the SDK for the embedded watch complication too, which then fails
with *"'accessoryCorner' is unavailable in iOS"* — a red herring.
`-destination 'generic/platform=iOS Simulator'` alone builds clean.

The green gate, all four targets:

```bash
xcodebuild test -project macos/Headroom.xcodeproj -scheme Headroom -configuration Debug -derivedDataPath macos/.build CODE_SIGNING_ALLOWED=NO
```

```bash
xcodebuild build -project macos/Headroom.xcodeproj -scheme HeadroomMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath macos/.build-ios CODE_SIGNING_ALLOWED=NO
```

```bash
xcodebuild build -project macos/Headroom.xcodeproj -scheme HeadroomWatch -destination 'generic/platform=watchOS Simulator' -derivedDataPath macos/.build-watch CODE_SIGNING_ALLOWED=NO
```

```bash
./scripts/check-glossary-copy.sh
```

When several agents share the tree, verify in a worktree at your own commit
rather than in the shared checkout — otherwise you are building someone else's
half-finished work and cannot tell whose failure you are looking at:

```bash
git worktree add --detach /tmp/verify HEAD
```

## The board

There is one ESP32 on one desk and it takes one owner at a time. Before you
touch it, **check that nothing else is using it, and stop if something is.**
Do not kill the holder to get your turn.

```bash
./scripts/flash-esp32.sh
```

That does the check and refuses to race. Use it instead of `pio run -t upload`.

`Headroom.app` launches `host/headroom_server.py`, which holds
`/dev/cu.usbmodem*` open to push `/usage` to the board over USB-CDC. Flash
while the app is running and the two fight for the port — and **esptool does
not fail cleanly.** It can write part of the app partition and then stop
responding, which leaves the board unbootable.

The failure reads as a hardware fault and isn't:

| What you see | What it actually is |
|---|---|
| `The chip stopped responding` mid-write | Something else owns the port |
| `device reports readiness to read but returned no data` | Same, on the retry |
| Board dark, port still enumerates | Partial app partition — it can't boot |

Recovering a half-written board needs hands: hold **BOOT**, tap **RESET** (or
replug USB), release BOOT, then flash again. OTA cannot save you, because OTA
needs a firmware that boots far enough to bring up Wi-Fi.

To check by hand:

```bash
lsof /dev/cu.usbmodem*
```

**Quitting `Headroom.app` is not enough, and neither is `kill`.** The host
server runs from a `KeepAlive` LaunchAgent, so it is detached from the app
(PPID 1) and launchd restarts it within seconds of any kill. You will watch the
PID change and the port stay busy.

Stop the agent, flash, put it back:

```bash
launchctl bootout gui/$(id -u)/com.centaur-labs.headroom
./scripts/flash-esp32.sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.centaur-labs.headroom.plist
```

Always restore it. The board gets its usage data from that process, so leaving
it unloaded looks exactly like a broken board on the next boot.

## Boot splash art is generated

`firmware/src/boot_max.h` is generated — never hand-edit it. The mask, both
copper tables and the previews all come from one script:

```bash
.venv-shots/bin/python scripts/render_esp32_boot.py --emit-header firmware/src/boot_max.h --out /tmp/boot
```

`--out` writes stills plus an animated GIF of the sequence at the real frame
timings, so the splash can be judged without a reflash. The venv is the one
`scripts/generate_screenshots.sh` builds; it only needs Pillow.

The splash plays on cold boot only — `esp_reset_reason()` gates it to
`POWERON`/`BROWNOUT`, and holding BOOT at power-on skips it. An OTA push or a
watchdog reboot goes straight to the amber ROM checklist, so the dev loop
doesn't pay four seconds an iteration.

`connectWifi()` is called **before** the splash in `setup()` on purpose. The
animation runs while the radio associates, which is time the board spends
anyway. Move it back after the splash and the show starts costing real
time-to-first-data.

`scripts/render_esp32_preview.py` and `render_esp32_boot.py` redraw what the
panel draws at the same logical 448x368, with text through
`scripts/gfx_font.py` — the same 5x7 glyphs and `6*size` metrics Arduino_GFX
blits, not a lookalike in a desktop font. Change layout in
`firmware/src/main.cpp` and change it in the renderer too, or the previews
start lying.

## Versioning

`host/VERSION` is the marketing version, hand-bumped. Apple build numbers come
from `git rev-list --count HEAD` and are not tracked.

**Each coherent set of changes gets exactly one release.** Increment the patch.
When the patch would pass 9, roll to the next minor and reset it:

| From | Change | To |
|---|---|---|
| 1.1.0 | anything shippable | 1.1.1 |
| 1.1.8 | anything shippable | 1.1.9 |
| 1.1.9 | anything shippable | **1.2.0** |
| 1.9.9 | anything shippable | **2.0.0** |

Never go past `.9`. `1.0.10` and `1.0.11` are shipped overshoots from before
the rule and stay tagged where they are; the roll they were owed happens at the
next release off them, which is why 1.0.11 is followed by **1.1.0** and not
1.0.12.

The number is claimed at merge, not at branch. Several branches sitting on
unmerged bumps is the normal state here, and each one was numbered against the
`main` it forked from — so the second one to land is wrong by the time it
lands. Take the number from `main`'s current `host/VERSION`, and expect to
renumber if someone beats you to it. Nothing downstream can undo a version:
tags, the GitHub Release and TestFlight builds only ever move forward, so
shipping a number strands every lower one still in flight.

Do not bundle unrelated work into one version. A release whose notes read as a
list of things that happened is a release nobody can reason about later.

## Releasing

**A bump to `host/VERSION` landing on `main` is the release.** The workflow
tags, notarizes, publishes the GitHub Release, and uploads to TestFlight with
nothing running locally. Ordinary commits to `main` publish nothing — the gate
only fires on a version it has not tagged.

That has one consequence worth stating plainly: **you cannot ship a subset of
`main`.** The bump ships whatever is on `main` at that moment, documented or
not. So one-set-per-release means one branch per set, merged and shipped one at
a time:

```
branch per set  →  merge to main  →  bump + push  →  ships  →  next set
```

Land your set with **no** version bump. The bump is a separate `chore: bump to
X.Y.Z` commit made when that set is ready to go out, and it is the last thing
before pushing. If someone else's unshipped work is sitting on `main` when you
bump, it rides along — check `git log` against the last tag before bumping, and
either wait or document what came with it.

`scripts/cut-release.sh` and the workflow both refuse a version with no
`CHANGELOG.md` section, because that section becomes the release notes.

## Working alongside other agents

Assume someone else is committing to this repo right now, possibly to your
branch.

- **Append only on anything shared.** Never `--amend`, `rebase`, `reset`, or
  force-push a branch someone else may be on. Re-check `git log -1` immediately
  before any history rewrite; HEAD may not be where you left it. An amend that
  lands on someone else's commit silently replaces their message and folds your
  changes into their commit.
- **Your branch is not private** unless you made it and said so. Prefer a
  branch named for your set.
- **Stage your own hunks.** A shared working tree accumulates other agents'
  edits in files you also touched. `git commit -a` sweeps them into your commit.
  Check `git status` and stage paths explicitly; for a file with both your work
  and theirs, stage only your hunks and put their working copy back.
- **Regenerate the project after pulling.** A new file under `Shared/` will not
  be in someone else's generated `.xcodeproj`, and the failure reads as a
  missing type rather than a stale project.
- **`CHANGELOG.md` is the hottest file here.** Add your bullets, do not
  reformat around them.

## Copy

User-facing chrome lives in `Shared/HeadroomCopy.swift`, mirrored by
`docs/glossary.md` and by `LABEL_*` in `firmware/src/main.cpp`.
`scripts/check-glossary-copy.sh` fails the build on banned phrasings and on
alarm colour in the quota and burndown views. Add new surfaces to its search
path when you create them.

Ring and pace semantics are a cross-platform contract: `docs/rings.md`, with
`Shared/HeadroomRings.swift` as the implementation and the firmware mirroring
its constants. Changing one means changing all of them.

Attention rollup scoring is the same kind of contract: `docs/attention.md`.
Weights and ages stay hardcoded product policy — do not add an Attention
Settings pane. Gateway prefs live under Coding agents; see
`docs/agent-attention.md`.

## Multi-Mac

Settings sync between Macs over CloudKit, one record per machine, written by
its owner and read by everyone else ([docs/multi-mac.md](docs/multi-mac.md)).
Four rules are load-bearing if you touch it:

- **The folder transport cannot live in iCloud Drive.**
  `~/Library/Mobile Documents` is TCC-protected, and the host is a LaunchAgent:
  it can create and write files there and is refused `listdir` on the same
  directory. Every Mac publishes, none can enumerate, nothing errors. This is
  why the transport is CloudKit and why the app owns it — an entitlement is not
  subject to TCC and a daemon cannot hold one. `icloud_dir` still selects the
  folder, which is correct for Dropbox or Syncthing and wrong for iCloud Drive.
- **A machine writes only its own record.** That is the entire reason there are
  no conflicts. Anything that writes a peer's record, or a shared one,
  reintroduces the problem the design exists to avoid.
- **Never construct a `CKContainer` without checking
  `MachineCloudSync.isAvailable` first.** On a binary whose signature lacks the
  entitlement — which is every local build — the initializer raises an
  Objective-C exception that Swift cannot catch, so the app dies at launch
  instead of degrading. The check reads the entitlement off our own signature.
- **The iCloud entitlements are not in `Headroom.entitlements`.** They are
  restricted, `codesign` does not validate them, and an app carrying them with
  no provisioning profile signs, notarizes, downloads and is killed on launch.
  `Headroom-iCloud.entitlements` is merged in by `scripts/build-app.sh` only
  when `HEADROOM_PROVISION_PROFILE` supplies one. No profile, no keys, and the
  artifact matches what shipped before the feature.
- **In CI that profile comes from the `MACOS_PROVISION_PROFILE` secret**, and
  its absence is invisible in a green run. Through 1.2.0 the workflow never set
  the variable, so every published release was notarized and had iCloud off.
  Grep the build log for `multi-Mac CloudKit is off` before believing a release
  can sync. Entitlements are sealed into a signature, so an already-downloaded
  app never gains CloudKit — it takes a new release.
- **The merge stays in Python.** `MachineCloudSync.swift` carries bytes and
  holds no opinion about them. A second implementation of last-writer-wins
  would drift, and the symptom would be settings quietly reverting on one Mac.
- **`app_config.SHARED_CONFIG_KEYS` is a whitelist, not a blocklist.** The file
  it reads holds the host token. A new config key is local until someone adds
  it there on purpose.

Per-machine facts — local servers, git commits, attention events — are
*reported* with an owner and never merged. A merged list would describe a
computer that does not exist.

Testing note: the folder transport is what the suite exercises, because it
needs no entitlement. CloudKit itself is only reachable from a signed build, so
a green `xcodebuild` says the code compiles and nothing about whether the
container answers.

## Layout

| Path | What |
|---|---|
| `host/` | Python host, stdlib only, serves `/usage` |
| `macos/` | Menu bar app + `project.yml` (every target) |
| `ios/` | iPhone companion |
| `watch/` | Watch app + complications ([docs/watch.md](docs/watch.md)) |
| `widget/` | One widget source, built for iOS and macOS |
| `Shared/` | Models, copy, palette, rings, chart math — compiled by several targets |
| `firmware/` | ESP32 |
