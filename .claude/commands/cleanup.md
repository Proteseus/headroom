---
description: Land every unshipped set on main as its own patch release, then leave a clean tree
---

# Cleanup: get back to a clean main

Run this in a fresh session when nobody else is working in the repo. It takes
whatever state things are in — feature branches, uncommitted work from several
sessions, commits sitting unshipped on `main` — and leaves:

- every finished set released from `main` as its own patch version, each with
  its own CHANGELOG section and its own tag
- nothing dirty except work you were explicitly told to leave
- a checkout sitting on `main`, which is where work happens here

Read `AGENTS.md` first. It governs everything below, and where the two
disagree, `AGENTS.md` wins.

## 0. Check nobody else is live

`git worktree list`, `git status`, and `git log --all -20 --format='%h %cr %s'`.
If another session looks like it is mid-change (a worktree you did not make,
commits from the last few minutes, a half-applied edit), say so and stop. This
command rewrites nothing, but it does publish, and publishing someone's
half-finished work is not recoverable.

## 1. Inventory first, act second

Report before touching anything:

- **Unshipped on main:** `git log --oneline $(git describe --tags --abbrev=0)..main`
- **Branches:** `git branch -v --no-merged main`, then for each one
  `git cherry -v main <branch>`. Use `git cherry`, not the commit list —
  branches here get cherry-picked into one another, so the same change exists
  under two SHAs and `--no-merged` keeps reporting content that already
  shipped. A `-` prefix means already applied, `+` means genuinely outstanding.
- **Dirty:** `git status --short`
- **Bumps already in flight:** `git log --all --oneline --grep='^chore: bump'`
  since the last tag. Several branches may each carry one, and they may claim
  the same number or leapfrog each other. Treat every one as a guess someone
  made, not as a decision.
- **Last tag** vs `host/VERSION`

Then present the sets you propose to ship, in the order you propose to ship
them, with a version for each — and **ask before starting**. Getting the
partition wrong is the expensive mistake; everything after it is mechanical.

## 2. Partition into sets

One coherent set per release. A set is one thing a user would recognise, the
way "watch complications" or "the activity feed reads at a glance" are things.
Do not bundle unrelated work into a version, and do not split something that
only makes sense whole. Docs and chores ride along with the next set and need
no entry of their own unless behaviour changed.

For uncommitted work, do not try to judge from a diff whether somebody was
finished. You cannot, and guessing wrong publishes half-built work. Ship only:

- what is already committed on a branch, and
- uncommitted files the person running this command **named as theirs and
  finished**

Everything else dirty stays exactly where it is and goes in the final report,
listed by path. Never discard, stash-drop, or check out over work you did not
write — ask. If the invocation named no uncommitted work, ship branches only.

## 3. Ship each set, one at a time

1. **Land it on main.** Commit with explicit paths, never `-a`. If a file holds
   both your set and another session's in-flight edit, stage only your hunks
   and leave theirs in the working tree.
2. **Verify at that commit**, in a worktree rather than the shared checkout —
   `git worktree add --detach /tmp/verify HEAD` — running the four gates in
   `AGENTS.md` (macOS `xcodebuild test`, the iOS build, the watch build,
   `./scripts/check-glossary-copy.sh`), plus `python3 -m unittest discover` in
   `host/` when the host changed. Export the beta toolchain first or the watch
   and iOS builds fail with *"watchOS 26.5 is not installed"*, which
   `AGENTS.md` flags as a red herring and which you will otherwise chase once
   per set:

   ```bash
   export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
   ```

   If a gate fails, stop and report. Never ship red.
3. **Write the CHANGELOG section.** If a section for your version already
   exists — someone bumped ahead of you and wrote one — extend that section
   rather than opening a second. Otherwise append above the previous version.
   Either way do not reformat around other people's bullets. It becomes the
   GitHub Release body, so write it for someone deciding whether to update,
   not for the diff.
4. **Check what rides along.** `git log $(git describe --tags --abbrev=0)..main`
   before every bump: a bump ships whatever is on `main`, documented or not.
   Anything user-visible that arrived without an entry gets one in your section.
5. **Bump** in its own `chore: bump to X.Y.Z` commit carrying `CHANGELOG.md`,
   `host/VERSION`, and `macos/Version.xcconfig`
   (`./scripts/version-env.sh --write-xcconfig`). Confirm the gate agrees:
   `./scripts/changelog-section.sh X.Y.Z`.

   First check whether the set you just landed **already dragged a bump commit
   onto `main`** — branches here are often bumped before anyone decides the
   order, and a branch can carry more than one. What matters is the final
   `host/VERSION` on `main`, since that is all the gate reads. If it is already
   the number you want, do not author a second bump; verify the three files
   agree and move on. If it is not, correct it in one bump commit.
6. **Push `main`. That is the release** — the workflow tags, notarizes,
   publishes, and uploads to TestFlight with nothing running locally.
7. **Watch it land:** `gh run list --limit 3`, `gh run watch`. The macOS job
   must go green. **The iOS/TestFlight job is known-red on signing** — record
   it and move on; fixing signing is its own set, not part of cleanup.
   If the **macOS** job goes red, stop the whole command there. Do not start
   the next set and do not try to fix it in passing: a tag already exists for
   that version, so the recovery is a new patch version, which is a decision
   for a human. Report which job failed and what it said.
8. Only then start the next set. A second bump before the previous tag exists
   leaves the gate looking at a version it cannot place.

**Numbers:** patch increments, never past `.9`, roll the minor at `.9` — the
table in `AGENTS.md`.

Compute every version from the tag that exists **at the moment you merge**,
and recompute after each release. Bump commits sitting in branches are
guesses, not decisions: two branches will happily claim the same number, and a
third will leapfrog to a minor nobody agreed to. None of that is authoritative
and none of it is a reason to skip a number.

So if a branch carries a bump whose version is wrong — already tagged, claimed
by another branch, or simply out of sequence — renumber it as you land it. A
version the gate has already tagged publishes nothing at all, and that failure
is silent.

## 4. Branch hygiene, last

Once a branch's content is released from `main`, list it as redundant and
offer to delete it.

Judge that by content, not by SHA — `git cherry -v main <branch>`. A branch
whose commits were cherry-picked elsewhere still shows as unmerged under
`git branch --no-merged` for ever, and a branch that is genuinely superseded
should not be kept alive by a stale SHA comparison. Every line prefixed `-` is
already applied; a branch with no `+` lines is safe to delete.

Never delete a branch with `+` lines, never force-push, never rewrite anything
already pushed.

## 5. Report

- each set: version, tag, and whether the release job went green
- anything that rode along (should be nothing undocumented)
- what is still dirty, and why it was left
- what needs a human: TestFlight signing, secrets, and anything you declined
  to guess at

## Constraints

- The gates are the build. Do not write tests, boot simulators, or drive the
  UI to prove something works.
- Never download an SDK, toolchain, or simulator runtime to unblock a gate.
  Stop and ask.
- Leave the tree green and the checkout on `main`.
- No em dashes in changelog prose.
