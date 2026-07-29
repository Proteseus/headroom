# Headroom glossary

Canonical names for the same concepts on ESP32, macOS, iOS, and widgets.
`Shared/HeadroomCopy.swift` is the Swift source. Firmware mirrors the same
words in `firmware/src/main.cpp` (see the `LABEL_*` constants). Host-served
titles for sources and pools live in `host/sources_config.py`.

When you rename something here, update the Swift copy, firmware labels, and
any hardcoded chrome that still bypasses them.

## Product

| Term | Meaning |
|---|---|
| **Headroom** | Product name on every surface |

## Navigation & sections

| Term | Meaning | Surfaces |
|---|---|---|
| **Overview** | Home summary | macOS tab, iOS tab |
| **Quotas** | Short nav label for coding quota detail | iOS tab |
| **Coding quotas** | Section title above the rings | macOS, iOS |
| **Activity** | Merged deploys / commits / Actions feed | iOS tab, macOS section, ESP32 home mode |
| **Services** | Supabase, Plausible, local servers | iOS tab (Mac stacks the same panels without a tab) |
| **Local servers** | Listening ports panel | macOS, iOS |
| **Settings** | Preferences | macOS window, iOS tab |
| **General** | Host endpoint, dashboard density, welcome, Other Macs | macOS Settings |
| **Sources** | What to watch — AI tools, extra accounts, dev tools | macOS Settings, iOS Settings, Welcome |
| **What to watch** | Welcome rail title for the Sources step | macOS Welcome |
| **Integrations** | Hub for Supabase / Plausible / GitHub keys | macOS Settings |
| **Connection** | Which Mac the phone talks to | iOS Settings |
| **Permissions** | Mac-granted phone capabilities (read-only on iOS) | iOS Settings |
| **iPhone** | Pairing + grants on Mac; notifications on iOS | macOS Settings, iOS Settings, Welcome |
| **On your phone** | Welcome rail title for the iPhone step | macOS Welcome |
| **About** | Product credit in Settings: icon, version, creator | macOS, iOS |
| **Created by Michell Zappa** | Personal credit on About (LICENSE copyright) | macOS, iOS |
| **Centaur Labs** | Publisher line on About (App Store entity) | macOS, iOS |
| **Attention** | Warning / status card | macOS, iOS |
| **Answer coding agents** | Mac-granted iPhone permission to answer an agent approval request | macOS, iOS |
| **Using Codex at** | Path to the Codex executable Headroom discovered and is supervising | macOS |
| **Coding agents** | Provider setup and attention gateway settings | macOS |
| **Claude Code hooks** | Managed Claude lifecycle and permission integration | macOS |
| **Install hooks** / **Reinstall hooks** / **Remove hooks** | Manage only Headroom-owned entries in Claude settings | macOS |
| **Send test attention** | Add a harmless Claude test row to the common feed | macOS |
| **Other Macs** | iCloud settings sync between Macs (under General) | macOS Settings |

Do not title the activity feed **GitHub**. That word is reserved for the
**GitHub Actions** source.

### Activity row states

Every row says its state in a word as well as a colour and a glyph, so the
feed still reads in greyscale. Host status string → word, mapped once in
`Shared/ActivityStatus.swift`:

| Host status | Word | Reads as |
|---|---|---|
| `error`, `failure` | **Failed** | Red, and sorted above the rest under **N need attention**. Tinted per row — the feed is one list of equal items, not a box stacked on a list |
| `building`, `initializing` | **Building** | Amber. In flight |
| `running` | **Running** | Amber. In flight |
| `queued`, `pending` | **Queued** | Amber. In flight |
| `ready` | **Deployed** | Green. Finished well |
| `success`, `completed` | **Passed** | Green. Finished well |
| `canceled` | **Canceled** | Grey — nobody has to go look at it, so it is not red |
| `pushed` | **Pushed** | Grey. Routine |
| `local` | **Local** | Grey. Committed, not pushed |
| `committed` | **Committed** | Grey. Routine |

Green means *finished well*, never *happened*. A pushed commit is grey; if
push turned green, the word would stop distinguishing a shipped deploy from a
`git push`.

## Charts & meters

| Term | Meaning | API / id |
|---|---|---|
| **Burndown** | Remaining-% over time for one pool | `burndown` |
| **Overall burndown** | Same chart across all coding providers | `burndown` / `burndown_primary` |
| **Daily burn** | Per-day %-point burn across providers | `by_day` |
| **pts / day** | Unit subtitle for daily burn | — |
| **Headroom rings** | Concentric usage + pace indicator | see `docs/rings.md` |
| **N% used** | The rings' reading | — |
| **N% left** | The burndown's reading (remaining) | — |
| **Empty Thu** | Forecast reaches zero before the pool renews | — |

Rings say **used**, burndown says **left**. Keep the word attached to the
number wherever both glyphs share a surface — the watch's rectangular
complication does — so they never look like one figure disagreeing with
itself. Where only one date fits, **Empty** outranks **Resets**.

Overall burndown’s optional subtitle is just **7 days** (don’t restate “all quotas”).
The domain is a fixed local week — today−3 … today+4 — so history stays readable
and far-out resets don’t stretch the axis. Forecasts crop at each reset (and at
empty); each in-range reset is an accent dotted vertical rule, and the legend
shows **Resets …**.

A reset the provider hands out early — Codex clearing a week you had already
spent — is a **granted** reset. On the **Codex** burndown (not Overview) it is a
solid accent rule where an upcoming one is dotted, captioned **Reset granted · N
pts back**. Scheduled rolls get no mark; the axis already ends on those. The
host detects them in the sample log (`burndown[].resets`), so the mark and the
history agree by construction.

A banked Codex reset credit has its own deadline, shown on the Codex quota card
as **N reset credits** with expiry labels — not as a renewal mark on Overview.

Pool-scoped burndown titles are `"{pool title} burndown"` (e.g. `Weekly burndown`).
Provider charts share one X-axis rule across Mac / iOS / ESP32: at most **seven
weekday-named columns** (never day-of-month numbers); windows longer than a week
clip to seven days covering now; sub-day sessions get hour ticks instead of a
blank axis.

## Status

| Term | Meaning |
|---|---|
| **Connected** | iOS link health when the Mac host is reachable |
| **Mac unavailable** | iOS cannot reach the host |
| **Reconnecting…** | Host answered again; forcing a source sync |
| **Refreshing…** | In-flight poll / sync while already connected |
| **All clear** | Healthy summary — host default, Attention card, and the Activity feed with nothing failing |
| **Needs attention** | Warning fallback when a reason has no summary; counted as **N need attention** above the Activity feed |
| **Collecting history** | Burndown empty / early verdict |
| **Clear** | Dismiss attention on every surface |
| **Refresh all** | Force-sync every source |

Do not use **All clear** for connection health — that word belongs on the
Attention card. The Overview status row uses **Connected** / **Mac unavailable**.

## Empty states

Keep these short; don’t explain the pipeline.

| Term | Use |
|---|---|
| **No history yet** | Burndown chart empty |
| **No burn history yet** | Daily burn empty |
| **No coding sources** | No quota providers enabled |
| **No activity yet** | Activity feed empty |
| **No local servers** | Local servers empty |
| **Waiting for Mac sync** | iOS before first payload |
| **Open Headroom on iPhone** | Watch before first payload — it cannot reach the Mac itself |
| **Searching…** | Bonjour discovery in progress |

## Welcome (macOS first run)

The eight-pane window shown once per install, and again from Settings →
**Show welcome**. It is a window rather than popover content because the
popover is `.transient` and hangs off the very icon the walkthrough points at.

Only names reused across surfaces live in `HeadroomCopy`; the pane prose is
macOS-only and stays in `macos/Sources/WelcomeView.swift`.

| Term | Use |
|---|---|
| **Welcome to Headroom** | Window title and first pane heading |
| **Headroom lives here** | Callout pointing at the menu bar icon |
| **Start using Headroom** | Final pane's button; closes the window and opens the dashboard |
| **Show welcome** | Settings row that reopens the window |

## Sources (host registry titles)

Ids stay lowercase; titles are user-facing. `group` is the Settings /
onboarding section the row lands in — never mix the two lists in one
undifferentiated pile of toggles:

| id | Title | group |
|---|---|---|
| `claude` | Claude | `ai` |
| `codex` | Codex | `ai` |
| `cursor` | Cursor | `ai` |
| `copilot` | Copilot | `ai` |
| `gemini` | Gemini | `ai` |
| `windsurf` | Windsurf | `ai` |
| `jetbrains` | JetBrains AI | `ai` |
| `zed` | Zed | `ai` |
| `vercel` | Vercel | `devtools` |
| `git` | Git | `devtools` |
| `github` | GitHub Actions | `devtools` |
| `supabase` | Supabase | `devtools` |
| `plausible` | Plausible | `devtools` |
| `local` | Local | `devtools` |

## Source groups

Membership comes from `host/sources_config.py` (`GROUP_AI` / `GROUP_DEVTOOLS`,
served as `sources[].group`). Section titles are chrome and live in
`Shared/HeadroomCopy.swift`:

| Term | Meaning | Surfaces |
|---|---|---|
| **AI coding tools** | Claude / Codex / Cursor / Copilot / … — plan left, no key to paste | macOS Settings + onboarding, iOS Settings |
| **Dev tools** | Vercel, Git, Actions, Supabase, Plausible, local servers | macOS Settings + onboarding, iOS Settings |

Don't call the first group **Sources** on its own, and don't call the second
**Activity** — that word belongs to the merged feed.

## Focus (the top 3)

The providers the compact surfaces draw: menu-bar tanks, the iOS widget, and
the ESP32 glance slots. Picked host-side from the pinned order (enabled only,
`sources_config.FOCUS_LIMIT`) and served as `focus` in `/usage`, so no surface
computes its own top-N. Drag to reorder under Mac Settings → AI coding tools.

Say **top 3** in user-facing copy, not "focus" — that word is API vocabulary.

Pool titles (`Session`, `Weekly`, `Total`, `API`, …) come from the host
`PoolSpec` and should not be re-hardcoded in UI chrome when the API supplies them.

## Colour

Colour carries one meaning per surface. Don't borrow it for emphasis.

| Where | Rule |
|---|---|
| **Quota meters, burndown** | Provider accent only. Exhaustion desaturates (`tint.drained()`); nothing turns red or orange |
| **Attention card, source health dots, Activity rows** | Green / amber / red — this is the *only* place alarm colour belongs, and never alone: the row carries a glyph and a word too |
| **Provider accent** | `sources_config.Source.accent` → `providers[].accent` / `sources[].accent`, mirrored by firmware `COL_*` and `UsageProvider.tint` |

**The burndown card never alarms.** "Runs out tomorrow 04:18" is a reading, and
the words already deliver it; painting it red says the same thing a second
time, louder. Burning exceeding Budget is visible in the cell beside it. This
was settled in `fd29592` ("drop distinct critical red tint") and then
reintroduced by a later refactor, so `scripts/check-glossary-copy.sh` now fails
the build if `Color.red` / `.orange` reappears in `BurndownCard.swift`,
`QuotaSection.swift`, or `DailyBurnCard.swift`.

If a genuinely new state needs to shout, add it to the Attention card — not to
a meter.

## What stays surface-specific

- Layout / IA (popover tabs vs iOS tab bar vs ESP32 pages)
- Host prose (`headline`, `verdict`, attention `reasons`)
- Accessibility strings that add context around a base term
