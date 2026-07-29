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
