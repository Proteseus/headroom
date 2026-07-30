# Changelog

Marketing versions come from [`host/VERSION`](host/VERSION); every entry below
is a `v`-prefixed git tag. Apple build numbers (`git rev-list --count HEAD`)
are not tracked here because they move on every commit.

Add a section here before cutting a tag. `scripts/cut-release.sh` refuses to
tag a version that has no entry.

## 1.1.9 — 2026-07-30

### Fixed

- Claude auth no longer borrows Claude Code's Keychain on every poll. Headroom
  imports the plan token once into `~/.headroom/oauth/` (one file per account),
  refreshes only that copy, and never writes back into Claude Code's item. A
  Keychain Deny stays denied until you refresh the source in Settings, instead
  of retrying every 20 seconds and re-prompting. Named Claude accounts each get
  their own Headroom file, same as before.


### Added

- Settings → General can open Headroom at login. macOS may still ask once in
  Login Items; the toggle says so and links there when approval is pending.

## 1.1.7 — 2026-07-30

### Changed

- Named accounts next to a brand mark show the user label (`Work`), not
  `Claude · Work`. The mark already names the tool; repeating it is how a row
  of Claude tabs all truncated to "Claude…". Full titles stay in Settings, the
  menu bar and other text-only surfaces.

## 1.1.6 — 2026-07-29

### Added

- Coding agents can ask you things through Headroom. When Codex wants to run a
  command or change a file, the approval becomes an item you can answer from
  the Mac or the phone rather than a terminal you are not sitting in front of.
  Each request is held until it is answered or expires, so a question does not
  disappear when the session behind it drops. Codex is the first provider, and
  the feed does not care which agent a request came from.

### Changed

- Other Macs sync over iCloud instead of a shared folder, so there is no
  directory to agree on: turn it on and the Macs find each other. Setting
  `icloud_dir` to a path still uses the folder transport.
- Settings is organised around what you are looking for rather than which part
  of the app happens to own it.
- The watch tile drops its headline at small sizes. Around 160 by 72 points the
  legend, the percent gutter and the weekday labels all stop being readable, so
  the chart takes the whole tile instead of competing with text.
- A full ring keeps a visible seam at 12 o'clock where its two caps meet,
  rather than closing into a solid circle you cannot read a value off.

### Fixed

- A weekly countdown that briefly sampled under the wrong Claude login no
  longer sticks for the rest of the week. The held reset re-anchors when the
  live reading points at an earlier instant, so one account stops showing
  another's "6d 19h".

## 1.1.5 — 2026-07-29

### Fixed

- The iPhone app reaches TestFlight again. Every release since 1.0.9 built it
  and then failed to sign it, so testers stayed on a build from 28 July while
  the Mac app went on to 1.1.4. Releases now sign the export with the team's
  distribution certificate and named App Store profiles, rather than asking the
  build machine to create credentials it has no way to create.

### Added

- `scripts/ship-ios.sh` sends a release to TestFlight from a Mac for when the
  workflow cannot. It refuses to run on a dirty tree or away from the release
  tag: the build number comes from the commit, and a build uploaded under the
  wrong one cannot be taken back.

## 1.1.4 — 2026-07-29

### Added

- Headroom is aware of your other Macs. Settings → Other Macs turns on sharing,
  and each Mac then publishes a small summary of itself to a folder in your
  iCloud Drive: what it is burning, how many local servers it has up, and
  whether it needs your attention. The popover lists the others with their own
  timestamps rather than merging them into one reading, because two Macs are
  allowed to disagree. Off until you turn it on.
- Enabled sources, pinned provider order, accent colours and the non-secret
  half of `config.json` follow you between Macs. Opening Headroom on a second
  Mac adopts the settings already in the folder instead of starting from
  defaults. Credentials and machine paths are never synced. See
  [docs/multi-mac.md](docs/multi-mac.md).
- A first-run Welcome window introduces the menu bar app, dashboard, quota
  rings, burndown charts, iPhone, Apple Watch and ESP32 companion. Settings can
  reopen it later, and About now carries the app version and product credits
  on both Mac and iPhone.
- Banked Codex reset credits now show their own expiry deadline on burndown
  charts, distinct from quota renewals and provider-granted resets.
- The ESP32 glance includes a compact burndown view, recent local Git activity
  and clearer host connection diagnostics.

### Changed

- The Mac quota dashboard adapts its tabs and card grid to the number of
  enabled providers instead of reserving space for providers that are hidden.
- Multi-Mac sharing can be enabled, disabled and inspected directly in
  Settings, including the current Mac, discovered peers and sync directory.

### Fixed

- The LaunchAgent now runs from `~/.headroom` rather than the read-only bundled
  host directory, so runtime state and relative writes have a writable home.

## 1.1.3 — 2026-07-29

### Fixed

- Named Claude accounts now read the Keychain credentials for their own
  profile instead of reusing the default account, so each account reports its
  own quota and stale state.

## 1.1.2 — 2026-07-29

### Fixed

- The macOS download is signed with Developer ID and notarized. Earlier
  releases shipped ad-hoc signed, so Gatekeeper refused to open them and
  reported that it could not verify the app. The signing certificate stored in
  CI held a private key with no certificate alongside it, which left the build
  job with no usable identity and sent it down its unsigned fallback path
  without failing.

## 1.1.1 — 2026-07-29

### Added

- Provider marks now identify every coding quota across the Mac, iPhone, and
  ESP32 dashboards, including named accounts under each provider.

## 1.1.0 — 2026-07-29

### Added

- Headroom now runs on Apple Watch with quota-ring and burndown
  complications. The iPhone forwards its existing snapshot over
  WatchConnectivity, so the watch does not need a second API or direct access
  to the Mac.
- Provider-granted resets now remain visible instead of making the burndown
  look as if it forgot the previous window. Charts show the forgiven curve and
  reset marker, the activity feed records the grant, and the ESP32 receives a
  compact version of the same history.
- The ESP32 has a generated cold-boot sequence plus an on-screen connection
  diagnosis that distinguishes Wi-Fi, host resolution, token, HTTP, and USB
  failures. The new flashing helper refuses to race another process for the
  serial port.
- Claude, Codex, and Cursor marks now identify their tabs in the Mac
  dashboard, including named accounts under each provider.

### Fixed

- **Claude quota could sit fifteen hours out of date and still read as live.**
  Claude Code keeps per-MCP-server OAuth in the same Keychain item as your plan
  token. Once that item held only `mcpOAuth`, the search for credentials ended
  there instead of going on to `~/.claude/.credentials.json`, so every fetch
  failed and no fresh login could bring it back. The search now passes over a
  store that has no plan token in it, and when there is none anywhere it tells
  you to run `claude login` rather than naming a missing JSON key.
- A source that has been failing for a day no longer reports as one poll old.
  Payloads carry the moment they were fetched; the poll clock only ever knew
  when we last *tried*, and a failing source is retried on the same schedule as
  a healthy one. This is what the menu bar's "N minutes stale" line reads, so
  it had been stuck at one minute for the whole outage. Snapshots written
  before the field get their age from the cache file's mtime, so the count is
  right on the first poll after upgrading rather than a fetch later.
- Stale quota no longer drives anything measured against the clock. The
  percentages still show — last-known beats blank — but the countdown, the
  pace, and the burndown chart drop out instead of being computed off a reading
  that has stopped moving. A frozen `resets_in_s` counted down was the most
  convincing wrong number on the card: right shape, right units, ticking a dead
  window to zero in front of you. One missed poll is still treated as a blip
  and changes nothing.
- Stale readings are no longer written to the quota sample log. Re-recording
  one reading laid down a flat line indistinguishable from a real idle stretch,
  and each sample walked the derived window forward, so a source that stopped
  answering last night still showed windows rolling on schedule today.

### Changed

- `providers[]` carries `stale`, `age_s`, and `stale_for_s` per source, so a
  client can tell last-known numbers from current ones without inferring it
  from an absent countdown.
- Activity rows now state their outcome and what needs attention in words.
  Colour remains supporting information rather than the only status signal.
- Quota rings use the sampled burndown pace when it is available, and visibly
  mark a provider whose last-known reading is no longer updating.
- Unconfigured Plausible and Supabase services stay out of the Mac and iPhone
  dashboards until they are enabled in Settings.
- App icons now use process cyan, magenta, and yellow rings so their three
  bands remain distinct at small catalog sizes.

### Fixed

- The app no longer reports its own staleness as the host's. It fingerprinted
  the host it bundles once per launch, on the premise that a running .app owns
  a read-only bundle — false every time a build lands on top of a running copy.
  The app then compared a dead fingerprint against a live host and offered an
  update that reinstalled the host already running, for ever. The fingerprint
  now recomputes when the files under `Resources/host` move.
- Skew has a direction. A host reporting a newer release line than the .app is
  no longer replaced with an older copy; the banner names the app as the half
  that needs updating and drops the button.
- Starting the host waits for the host it started. A 200 on :8737 was taken as
  success, which the process being replaced answers on its way out — and which
  a foreign host answers for ever, since ours stands down by design when the
  port is taken. Startup now waits for the fingerprint it installed, and says
  so when something else owns the port instead of reporting success.
- One install at a time. Launch, the poll loop, the setup card and the skew
  banner each ran their own bootout/bootstrap; whoever lost the race read
  `/usage` from a host mid-restart, which is how "Host is up" and "Could not
  connect to the server" ended up on screen together.
- The LaunchAgent asks for `KeepAlive/SuccessfulExit=false`. The host exits 0
  on purpose when another process owns the port, but an unconditional
  `KeepAlive` ignores exit status and respawned it every 5 seconds for ever,
  each respawn rescanning a week of logs.
- One failed call no longer counts as "no host". A refused server stop or a
  single flaky poll replaced the whole dashboard with the onboarding sheet;
  that now keys on whether `/health` answers.
- The setup card re-checks while it is open, instead of showing three lines
  captured at three different moments.

## 1.0.11 — 2026-07-29

### Added

- The widget now runs in macOS Notification Center, not just on the phone.
  Rings on the small size, combined burndown on the medium one, same as iOS.
- The Mac widget is current rather than a refresh interval behind. The app is
  the source of its own data, so it writes the shared cache after every
  successful poll of its host. The phone can only write after a background
  refresh, which iOS schedules when it feels like it.

### Changed

- One widget source, `widget/HeadroomWidget.swift`, builds for both platforms.
  What differs is the group id, which macOS prefixes with the team, and the
  Info.plist and entitlements under `widget/ios` and `widget/macos`.
- Quota presentation logic moved out of the iPhone target into
  `Shared/QuotaPresentation.swift` so both widgets and both apps read one
  implementation.
- The Mac app and its extension share an App Group. The app is not sandboxed
  and the extension is, so the group is the only thing between them.

### Fixed

- `build-app.sh` signs the extension separately from the app instead of with
  `--deep`. The two take different entitlements, and `--deep` stamped the
  app's onto the sandboxed extension, which then lost the group container.
  The build now also verifies both ends resolve to the same group, because a
  mismatch fails as a widget that loads and draws the placeholder for ever.

## 1.0.10 — 2026-07-29

### Fixed

- Building the iPhone app from a clean clone failed for everyone outside the
  maintainer's Apple team: `No profiles for 'com.centaur-labs.headroom' were
  found`. The documented command had no unsigned path and no
  `-allowProvisioningUpdates`, so automatic signing could never mint anything.
  There is now a simulator build that needs no Apple account, and the device
  build documents the two things a fork must change first.

### Changed

- The signing table in `CONTRIBUTING.md` no longer claims iOS profiles are
  "nothing to edit". `com.centaur-labs.*` belongs to one team and Apple will
  not issue it to another.
- CI-equivalent iOS simulator build added to the contributor build list.

## 1.0.9 — 2026-07-28

### Added

- The ESP32 reads its providers, their order, and their colours from the host
  instead of carrying its own copy.
- Per-provider colour override in Settings.
- Richer widget overview and shared ring polish across Mac and iPhone.

### Changed

- Burndown chart math and canvas furniture extracted into `Shared/` so the
  three clients draw from one implementation.
- App icon regenerated from the ring glyph.

### Fixed

- Firmware pace dots, and host accent colours that did not always land.

## 1.0.8 — 2026-07-28

### Added

- More than one account per provider. Each account meters separately and the
  pool ranks fold them together.

## 1.0.7 — 2026-07-28

### Added

- GitHub Actions watch list in Settings, spanning repos from more than one
  owner.
- Supabase security advisors, fetched separately from project health, with UI
  on both clients.
- Host Settings API backing the watch list and advisor activity.

### Fixed

- The Mac app degrades gracefully against a host with no `/github/watch`
  instead of showing an empty pane.
- The `/usage` filter contract no longer pins itself to one firmware
  signature.
- Firmware builds its JSON usage filter once, in PSRAM.
- iOS archives export with automatic signing.

## 1.0.6 — 2026-07-28

### Fixed

- Firmware projection dashes run along path length and open up enough to read
  at desk distance.

## 1.0.5 — 2026-07-28

### Added

- Shared palette, compact number format, and a 7-day burndown axis used by all
  three clients.

### Changed

- Host derives `Source` detail, summary, and blank states from pools.
- `urllib` plumbing shared through `http_util`.

### Fixed

- Burndown never renders in the alarm tint, which previously read as a warning
  when nothing was wrong.

## 1.0.4 — 2026-07-28

### Added

- Host pins source order and ships a top-3 focus that every surface honours.
- Drag-to-reorder in Mac Settings, week burndown, and the app icon.
- Focus rendering on iOS quota surfaces and an ASCII-safe firmware glance.

### Changed

- Signing uses `$HEADROOM_TEAM_ID` instead of a hardcoded team.
- The generated Xcode project is no longer tracked. `macos/project.yml` is the
  source of truth.
- Contributing guide, security policy, and backlog added for the public repo.

### Fixed

- The host token stays out of the launchd logs.

## 1.0.3 — 2026-07-28

### Fixed

- Release CI imports the full Developer ID identity so notarization completes.

## 1.0.2 — 2026-07-28

### Fixed

- First attempt at the Developer ID import above. Superseded by 1.0.3.

## 1.0.1 — 2026-07-28

### Added

- First public macOS zip.
- iOS releases publish through `asc` to the Internal TestFlight group.
- App Store listing copy, privacy policy, icon, and framed iPhone slides.

### Fixed

- iOS declares itself export-compliance exempt so TestFlight can assign builds.
- TestFlight export uses manual App Store profiles.

## 1.0.0 — 2026-07-28

First tagged release.

### Added

- Menu bar app with a welcome flow, bundled-host control, and enabled-only
  providers.
- Registry-driven quota providers in the host, local detection, and `/setup`.
- `HeadroomMobile` companion app reading the same shared usage document.
- ESP32 firmware with a Cursor Total+API burndown overlay, stamped with a
  local build counter and commit hash.
- Shared models across Mac and iPhone under the Headroom name.
- Host `VERSION` fingerprint so the app can tell a stale LaunchAgent from a
  current one.
- Apple commit-count versions, notarization, and TestFlight CI.

### Changed

- Burndown and quota rings use brand-tint-only styling.
- GitHub Actions failures age out of Attention and the activity feed.

### Fixed

- iOS keeps the last `/usage` on disk when the Mac is unreachable, and forces a
  source sync when recovering from a stale archive.
- macOS forces a source sync after wake and shows a reconnecting status.
- Flat burndown projections are skipped rather than painting a misleading level
  bar.
