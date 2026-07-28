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
cd macos && ../scripts/sync-embedded-host.sh && xcodegen generate && xcodebuild test -project Headroom.xcodeproj -scheme Headroom -derivedDataPath .build CODE_SIGNING_ALLOWED=NO
```

```bash
cp firmware/src/config_example.h firmware/src/config.h && cd firmware && pio run
```

A full `.app`: `./scripts/build-app.sh` writes `dist/Headroom.app`, ad-hoc
signed, no Apple account needed.

CI runs all three on every PR. Keep it green.

## Signing

The repo defaults to the maintainer's Apple identifiers so releases build
unattended. You do not need them:

| Thing | Default | Yours |
|---|---|---|
| Team | `$HEADROOM_TEAM_ID` (992N457T8D) | `export HEADROOM_TEAM_ID=ABCDE12345` |
| Bundle prefix | `com.centaur-labs` | edit `macos/project.yml` |
| iOS profiles | minted by Xcode from `$HEADROOM_TEAM_ID` | nothing to edit |

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
