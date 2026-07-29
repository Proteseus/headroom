# Changelog

Marketing versions come from [`host/VERSION`](host/VERSION); every entry below
is a `v`-prefixed git tag. Apple build numbers (`git rev-list --count HEAD`)
are not tracked here because they move on every commit.

Add a section here before cutting a tag. `scripts/cut-release.sh` refuses to
tag a version that has no entry.

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
