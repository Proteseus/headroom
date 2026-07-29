# Two Macs

Headroom on a second Mac should feel like the same app, not a fresh install.
This is how that works, and — more usefully — what it deliberately does not
try to do.

## Most of it was already shared

Quota is account-scoped. Two Macs signed into the same Claude, Codex or Cursor
login read the same percentages off the provider, because the provider is
counting the account and not the machine. Same for Vercel, GitHub, Supabase and
Plausible. So the headline numbers on a second Mac were always right, and none
of them are synced by anything here.

What did not travel was everything around those numbers.

## Three tiers

**Already shared.** Every `pct`, every `resets_in`, every deploy and CI run.
Nothing to do. The only prerequisite on the second Mac is being signed into the
CLIs there, which you do anyway.

**Synced by this feature.** The settings that are the same person's answer on
any machine: which sources are enabled, the order you pinned providers in, the
colours you gave them, and the non-secret half of `config.json` — git authors,
Vercel teams, GitHub org filters, Plausible sites.

**Never merged, but reported.** Local servers, git commits, the Claude token
log, agent attention events, whether the ESP32 is on this desk. These are
genuinely different per machine and a merged list of them would describe a
computer that does not exist. Each Mac publishes a summary of its own and the
others show it with an owner and an age.

## Turning it on

Off by default, because it writes data to a folder that leaves the machine.

```json
{ "icloud_sync": true }
```

in `~/.headroom/config.json`, on each Mac. Restart the host, or wait a minute.

`icloud_dir` overrides where the machines meet. Empty means
`~/Library/Mobile Documents/com~apple~CloudDocs/Headroom`. Nothing in the
implementation is iCloud-specific but that default path — point it at Dropbox,
Syncthing, or a shared volume and the rest works unchanged.

## Why a folder and not CloudKit

The data lives in the Python host, not the Swift app. CloudKit would mean
mirroring it up into the app, out to iCloud, back down and into the host again:
a sync daemon written twice, plus a Developer ID provisioning profile in a
signing pipeline that does not have one. `NSUbiquitousKeyValueStore` is
documented as App Store distribution only, and Headroom ships notarized off
GitHub Releases. A folder both machines can see costs neither, and keeps the
host stdlib-only.

## Why it never conflicts

**A machine writes only its own file and only ever reads the others.**

```
Headroom/machines/<machine-id>.json
```

No file has two writers, so iCloud has nothing to make a conflict copy of.
There is no shared document to reconcile, no merge on the write path, and no
ordering problem. Each Mac derives its own view at read time and is allowed to
reach a different one — which is also the answer to a Mac that has been asleep
for a week. It is not "behind", it just knows less, and it says so with a
timestamp instead of pretending otherwise.

## How settings pick a winner

Per setting, not per file, so pinning Codex above Claude on the laptop does not
drag the laptop's colours along with it. `shared_prefs.py` flattens both stores
into one keyspace:

| Key | Value |
|---|---|
| `sources.enabled.<id>` | bool |
| `sources.accent.<id>` | `#RRGGBB`, or null for the registry colour |
| `sources.order` | pinned provider ids |
| `config.<key>` | whitelisted config.json keys |

Every key is always present, with an explicit null for "unset" — a missing key
and a cleared one have to be told apart, or clearing an accent on one Mac would
never travel.

Each key carries the wall-clock time it last changed, and the newest stamp
wins. Ties keep the local value, so a round that adopts nothing writes nothing.
Clock skew between two Macs on the same iCloud account is seconds; these
settings are changed by hand, minutes or months apart.

**The first round is a bootstrap, not a merge.** This is the part worth
understanding, because plain last-writer-wins gets it exactly backwards: on a
brand new Mac every setting is equally unstamped, so a merge would leave both
machines sitting on their own defaults. Instead:

- Folder already has machines in it → this Mac is **joining**, and adopts
  wholesale. That is what opening Headroom on a second Mac is for.
- Folder is empty → this Mac is the **origin**. Its config is stamped now, so
  it wins over the next Mac's untouched defaults.

After that first round it is ordinary last-writer-wins.

Local edits are detected *before* anything is applied. That ordering is the
whole loop-prevention argument: a value this Mac normalizes on the way in — a
pinned order naming a provider that only exists on the other Mac — is not
mistaken for a fresh local edit next round and bounced back. `test_icloud_sync.py`
asserts settling in one round and staying settled.

## What never syncs

Credentials, of any kind. `shared_prefs` reaches `config.json` only through
`SHARED_CONFIG_KEYS` in `app_config.py`, so the host token cannot be written to
the shared folder even by accident, and there is a test that greps the produced
files for one.

Also never synced: anything describing one machine's disk or moment —
`dev_root`, `codex_binary`, extra-account credential roots, the mobile pairing
token, local servers, git commits, the Claude token log, attention events.

## Layout

| File | Job |
|---|---|
| `host/machine_identity.py` | stable id, live display name |
| `host/shared_prefs.py` | the flat keyspace, and applying it back |
| `host/icloud_sync.py` | transport, merge, peer list |
| `Shared/HeadroomModels.swift` | `MachineSummary` off `machines[]` |
| `macos/Sources/MachinesSection.swift` | the popover rows |

`machines[]` is always in `/usage` with at least this Mac's own row, so a
single-Mac install has the same shape as a synced one and no client needs a
special case for sync being off.

## Not done yet

**Chart history.** `quota_samples.jsonl` is a log of what *this Mac watched
happen*, so a laptop that slept all week has a correct `week_pct` and a sparse
burndown chart. The merge is easy — thinned curves, local samples win, remote
fills gaps, max-pct within a bucket since usage only rises inside a window —
but it is a separate change from settings.

**Cross-machine control.** Answering an agent or stopping a server on the other
Mac. The attention ledger is already compare-and-swap guarded for it, but the
transport here is a folder that syncs on its own schedule, which is the wrong
shape for something you expect to happen now.

**The phone.** iPhone and Watch pair to one Mac, and that Mac now knows about
the others, so `machines[]` is already in the payload they fetch. Only the UI
is missing.
