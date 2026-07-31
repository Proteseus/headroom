# Contributing

Bug reports, board photos, and provider fixes are all welcome. Quota formats
drift constantly, so a report that says "Cursor shows 0% since yesterday" plus
the redacted shape of the local file is worth more than it sounds.

## Ground rules

- **The host is stdlib-only.** `host/` runs on the system `/usr/bin/python3`
  (3.9 on macOS 14) with no pip install, because it ships inside the `.app`.
  A change that needs a dependency needs a conversation first.
- **`/usage` is a contract.** Four surfaces read it: menu bar, iPhone, widget,
  ESP32. `host/test_contract.py` and `macos/Tests/ContractTests.swift` pin the
  shape. Change the shape, change both.
- **XcodeGen owns the project file.** `macos/project.yml` is the source of
  truth; `Headroom.xcodeproj` is generated and gitignored. Never hand-edit it.
- **Never commit credentials.** `firmware/src/config.h` holds Wi-Fi passwords
  and is gitignored. Tokens live in `~/.headroom/`, never in the repo.

## Build and test

```bash
cd host && python3 -m unittest discover -p "test_*.py"
```

```bash
./scripts/gen-project.sh && cd macos && xcodebuild test -project Headroom.xcodeproj -scheme Headroom -derivedDataPath .build CODE_SIGNING_ALLOWED=NO
```

```bash
cp firmware/src/config_example.h firmware/src/config.h && cd firmware && pio run
```

```bash
./scripts/gen-project.sh && cd macos && xcodebuild -project Headroom.xcodeproj -scheme HeadroomMobile -destination 'generic/platform=iOS Simulator' -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

The iPhone app embeds the watch app, so that last one needs an Xcode whose
watchOS SDK is actually installed — see
[docs/ios-companion.md](docs/ios-companion.md). Do not add `-sdk
iphonesimulator` to it.

A full `.app`: `./scripts/build-app.sh` writes `dist/Headroom.app`, ad-hoc
signed, no Apple account needed.

CI runs the host, firmware, and macOS test jobs on every PR; the iOS build is
local-only. Keep it green.

## Signing

The repo defaults to the maintainer's Apple identifiers so releases build
unattended. You do not need them:

| Thing | Default | Yours |
|---|---|---|
| Team | `$HEADROOM_TEAM_ID` (992N457T8D) | `DEVELOPMENT_TEAM` in `macos/Local.xcconfig` (gitignored), or export the env var |
| Bundle prefix | `com.centaur-labs` | `HEADROOM_BUNDLE_PREFIX` in `macos/Local.xcconfig` |
| iOS profiles | the maintainer's, already on their Mac | see below |

The Mac app and the iOS **simulator** build pass `CODE_SIGNING_ALLOWED=NO` and
touch none of this. Only an iOS **device** build, a notarized release, or a
TestFlight upload does.

A device build cannot go unsigned, and Apple will not mint anyone else a
profile for `com.centaur-labs.*`. Forks set `DEVELOPMENT_TEAM` and
`HEADROOM_BUNDLE_PREFIX` in a gitignored `macos/Local.xcconfig` (README,
"Signing as yourself"), rename the matching App Group, and build with
`-allowProvisioningUpdates` so Xcode registers the new ids. Full steps in
[docs/ios-companion.md](docs/ios-companion.md).

`scripts/build-app.sh` passes `CODE_SIGNING_ALLOWED=NO`, so a local Mac build
touches none of this. Only notarized releases and TestFlight uploads do.

## Adding a source

One entry in `SOURCES` in `host/sources_config.py`, tagged `group="ai"` or
`group="devtools"`. Dev tools stop there. A coding provider also needs a
fetcher module next to `codex_usage.py`, and it must:

- read what the vendor already wrote on this Mac, never ask for a new login
- degrade to `{ok: false, error: ...}` instead of raising
- keep the last good snapshot through a failure (`cache_util.keep_stale`)
- add a case to `host/test_new_quota_providers.py`

## Pull requests

Small and single-purpose. Say which surfaces you actually ran: the host tests
alone do not prove the menu bar still lays out, and none of it proves the board
still draws. Screenshots help for anything visual.

Commit messages follow what is already in `git log`: a `type: summary` subject
in the imperative, wrapped body explaining why rather than what.

## Releasing

Bumping `host/VERSION` on `main` **is** the release: CI tags, builds,
notarizes, publishes, and uploads to TestFlight on its own. So the changelog
section is not paperwork you file afterwards, it is part of shipping.

Every point version gets a section in [`CHANGELOG.md`](CHANGELOG.md), written
for someone deciding whether to update rather than for the person who wrote the
code. It becomes the release body. A bump without one fails the build rather
than shipping undocumented, and `scripts/cut-release.sh` refuses it locally
through the same script. Procedure in [docs/releasing.md](docs/releasing.md).
