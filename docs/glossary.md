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
| **Attention** | Warning / status card | macOS, iOS |

Do not title the activity feed **GitHub**. That word is reserved for the
**GitHub Actions** source.

## Charts & meters

| Term | Meaning | API / id |
|---|---|---|
| **Burndown** | Remaining-% over time for one pool | `burndown` |
| **Overall burndown** | Same chart across all coding providers | `burndown` / `burndown_primary` |
| **Daily burn** | Per-day %-point burn across providers | `by_day` |
| **pts / day** | Unit subtitle for daily burn | — |
| **Headroom rings** | Concentric usage + pace indicator | see `docs/rings.md` |

Overall burndown’s optional subtitle is just **7 days** (don’t restate “all quotas”).
The domain is a fixed local week — today−3 … today+4 — so history stays readable
and far-out resets don’t stretch the axis. Forecasts crop at each reset (and at
empty); each in-range reset is an accent dotted vertical rule, and the legend
shows **Resets …**.

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
| **All clear** | Healthy attention summary (host default + Attention card) |
| **Needs attention** | Warning fallback when a reason has no summary |
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
| **Searching…** | Bonjour discovery in progress |

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
| **Attention card, source health dots** | Green / amber / red — this is the *only* place alarm colour belongs |
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
