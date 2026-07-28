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

Pool-scoped burndown titles are `"{pool title} burndown"` (e.g. `Weekly burndown`).

## Status

| Term | Meaning |
|---|---|
| **Connected** | iOS link health when the Mac host is reachable |
| **Mac unavailable** | iOS cannot reach the host |
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

Pool titles (`Session`, `Weekly`, `Total`, `API`, …) come from the host
`PoolSpec` and should not be re-hardcoded in UI chrome when the API supplies them.

## What stays surface-specific

- Layout / IA (popover tabs vs iOS tab bar vs ESP32 pages)
- Host prose (`headline`, `verdict`, attention `reasons`)
- Accessibility strings that add context around a base term
