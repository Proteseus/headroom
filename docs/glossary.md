# Headroom glossary

Canonical names for the same concepts on ESP32, macOS, iOS, and widgets.
`Shared/HeadroomCopy.swift` is the Swift source. Firmware mirrors the same
words in `firmware/src/main.cpp` (see the `LABEL_*` constants). Host-served
titles for sources and pools live in `host/sources_config.py`, and the host's
own prose — `headline`, `verdict`, attention `reasons` — is written in
`host/burndown.py`. **The host is a copy surface, not a data source**: those
strings are the ones the ESP32 draws and VoiceOver reads, and no client can
retitle them. `scripts/check-glossary-copy.sh` searches `host/` for that
reason.

When you rename something here, update the Swift copy, firmware labels, host
prose, and any hardcoded chrome that still bypasses them. **A rename is a
release**, not a commit that rides along with something else: the iPhone
replays its last saved payload (**Recent history**) and the board holds strings
in flash, so for as long as a stale client is alive both spellings are on
screen somewhere. Clients must never persist host prose across a rename.

## The decisions under all of this

The tables below are the *what*. These are the *why*, and they are the ones
that get expensive to reverse.

**Percent is the only unit Headroom claims.** Anthropic bills in points,
Cursor in requests, GitHub in premium requests, OpenAI in credits. Headroom
flattens all of them to a share of a window, and that flattening *is* the
product — it is what lets one glance compare four plans. The cost is that
Headroom's numbers never reconcile with a provider's billing page, so the copy
must never borrow a provider's unit for a figure that isn't in it. No "pts",
no "credits", no token counts. If money ever lands on a surface (`host/pricing.py`
exists and is unused by the UI), it arrives as a second, separately labelled
axis — it does not get to reuse these words.

**Voice: second person, present tense, no first person.** Headroom says *you*
and names things; it never says *we*, *our*, or *I*, and it never apologises.
Actions are imperative (**Refresh all**, **Add a test row**), states are
fragments (**Not updating**, **On pace**). Welcome is allowed to be warmer than
Settings — that is a register, and it is deliberate — but it stays in the same
person. `check-glossary-copy.sh` fails the build on `Text("We `.

**Metaphors are zoned, one per axis.** Five families were in use at once and
they pointed three directions for one fact:

| Axis | Family | Words |
|---|---|---|
| State — how much is left | Fuel | tank, drains, **Empty**, full |
| Rate — is that sustainable | Pace | **On pace**, **Over pace**, to spare, over |
| History — how it got here | Burndown | burndown, daily burn, burn rate |
| Money | Provider's own | credits, grants — **only** where the provider bills that way (Codex reset credits) |

Do not mix them. A tank does not run "over budget"; a pace is not "empty".
The product name is the fuel family's, and it is the only place the metaphor
is stated as a noun.

**Telling time: prose says *when*, compact says *how long*.**

| Form | Looks like | Where | Field |
|---|---|---|---|
| Clock | `Thu 14:00`, `tomorrow 04:18` | `headline`, anywhere with a full line | `_when()` |
| Duration | `4d 44m`, `3d` | menu bar, watch, board, `Resets 3d` captions | `resets_in`, `fmt_resets()` |

One sentence gets one form. `58% left · 4d 44m. Out tomorrow 04:18` was two
time facts in two shapes on one line. The board's `verdict` is the documented
exception — at ~25 bytes it takes duration form, and each of its branches
returns only one time fact, so the two never meet.

**Times are 24-hour, English (U.S.), not localized.** Every string is a literal;
there is no `.strings` catalogue and `host/burndown.py` formats with `%H:%M`.
That was decided by default rather than on purpose — record it here so the day
it changes is a decision and not a surprise.

**Provider names belong to other companies.** Claude, Codex, Cursor, Copilot,
Gemini, Windsurf, JetBrains, Zed. Render them exactly as the vendor does, never
possessive (*Claude's quota*), never verbed, and never phrased so the reader
takes Headroom for an official integration. Headroom reads local files those
tools already wrote; it is not endorsed by any of them.

**Accessibility strings follow one order: name, then value, then state.**
"Claude, 42 percent used, 38 percent pace". Layout and host prose stay
surface-specific (see the end of this file), but the shape does not.

## Product

| Term | Meaning |
|---|---|
| **Headroom** | Product name on every surface |

## Navigation & sections

| Term | Meaning | Surfaces |
|---|---|---|
| **Overview** | Home summary | macOS tab, iOS tab |
| **Quotas** | Coding quota detail, reached from Overview (no longer its own iOS tab) | iOS |
| **Coding quotas** | Section title above the rings | macOS, iOS |
| **Activity** | Merged deploys / commits / Actions feed | iOS tab, macOS section, ESP32 home mode |
| **Services** | Supabase, Plausible, local servers | iOS tab (Mac stacks the same panels without a tab) |
| **Local servers** | Listening ports panel | macOS, iOS |
| **Settings** | Preferences | macOS window, iOS tab |
| **General** | Host endpoint, Open at Login, dashboard density, welcome, Other Macs | macOS Settings |
| **Open at Login** | Start the menu bar app when you log in to this Mac | macOS Settings |
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
| **Attention** | Warning / status card (scoring policy: `docs/attention.md`) | macOS, iOS |
| **Answer coding agents** | Mac-granted iPhone permission to answer an agent approval request | macOS, iOS |
| **Using Codex at** | Path to the Codex executable Headroom discovered and is supervising | macOS |
| **Coding agents** | Provider setup and attention gateway settings | macOS |
| **Claude Code hooks** | Managed Claude lifecycle and permission integration | macOS |
| **Install hooks** / **Reinstall hooks** / **Remove hooks** | Manage only Headroom-owned entries in Claude settings | macOS |
| **Add a test row** | Add a harmless Claude test row to the common feed | macOS |
| **Request** | The agent's own request, field by field, above the answer buttons | iOS |
| **Why** | The provider's stated reasons for asking | iOS |
| **Show request** / **Hide request** | Expand the bulk fields (file contents, replacement bodies) | iOS |
| **Shortened to fit** | This value is a prefix; the host clipped it | iOS |
| **Options** | The choices an agent is offering, each with why you would pick it | iOS |
| **Ask on Mac** | Decline to answer a question from the phone; it appears on the Mac | iOS |
| **Allow once** / **Always allow this exact request** / **Deny** | Answers to a permission request. The middle one saves a rule | iOS |
| **Saves the rule** | The exact rule an always-allow answer will write | iOS |
| **Start task** | Give an agent a folder and a prompt | macOS, iOS |
| **Reply to the agent…** | Free-text answer to a request | iOS |
| **Answer in the terminal** | This question is showing in both places; answer it where it was asked | iOS |
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
| **% / day** | Unit subtitle for daily burn | — |
| **Headroom rings** | Concentric usage + pace indicator | see `docs/rings.md` |
| **N% used** | The rings' reading | — |
| **N% left** | The burndown's reading (remaining) | — |
| **On pace** / **Over pace** | Whether the current burn lands inside the window | `verdict`, `headline` |
| **N% to spare** / **N% over** | Signed distance from an even spend | `headline` |
| **Empty Thu** | Forecast reaches zero before the pool renews | — |

Rings say **used**, burndown says **left**. Keep the word attached to the
number wherever both glyphs share a surface — the watch's rectangular
complication does — so they never look like one figure disagreeing with
itself. Where only one date fits, **Empty** outranks **Resets**.

Pace has two words and only two: **On pace** and **Over pace**. "Ahead of
pace" cuts both ways to a casual reader, and "On track" was a third word for
a state that already had one. `headline` and `verdict` say the same pair, so
moving between the board and the Mac never teaches a second vocabulary.

Slack against an even spend is signed and in percent: **12% to spare**,
**4% over**. The old `_points()` ran `abs()` over a signed delta and called
the result "4 points", so a pool four behind read exactly like a pool four
ahead.

Overall burndown’s optional subtitle is just **7 days** (don’t restate “all quotas”).
The domain is a fixed local week — today−3 … today+4 — so history stays readable
and far-out resets don’t stretch the axis. Forecasts crop at each reset (and at
empty); each in-range reset is an accent dotted vertical rule, and the legend
shows **Resets …**.

A reset the provider hands out early — Codex clearing a week you had already
spent — is a **granted** reset. On the **Codex** burndown (not Overview) it is a
solid accent rule where an upcoming one is dotted, captioned **Reset granted ·
N% back**. Percent even here: Codex genuinely grants credits, but the number
in this caption is a share of the window the chart draws, not a credit count.
Scheduled rolls get no mark; the axis already ends on those. The
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
| **Not updating** | The host is replaying a source's last good numbers; the age travels with it (**Not updating · 2 hours ago**) |
| **Needs sign-in** | That source's credential is missing or was rejected — `auth_required` on `providers[]` / `sources[]`. Ages the same way |
| **Clear** | Dismiss attention on every surface |
| **Refresh all** | Force-sync every source |

**Needs sign-in** outranks **Not updating** wherever both are true, which is
most of the time — a dead login also freezes the numbers. Staleness is shared
by rate limits and dropped networks and reads as something to wait out; only
this one names a thing the reader can go and do. `QuotaProviderInfo.statusNote`
picks between them so no surface has to.

Do not use **All clear** for connection health — that word belongs on the
Attention card. The Overview status row uses **Connected** / **Mac unavailable**.

### Service health

Supabase, Plausible and the Supabase advisors sit on the same axis as source
health: **does the reader wait, or go and do something.** The host's own
`error` string wins when there is one; these are the fallbacks for when there
isn't. `HeadroomCopy.serviceStatus(_:configured:)` picks between them.

| Term | Meaning |
|---|---|
| **N needs a key** | `configured == false` — nothing pasted yet. Keys live under Settings → Integrations |
| **N not reporting** | Configured, and it did not answer. Nothing to do but wait |
| **Plan unknown** | The provider didn't name the plan. Not a failure; the status label beside it already carries health |

**Nothing says "unavailable" any more** except **Mac unavailable**, which is
the transport and keeps the word. It had grown to cover a missing key, a
failed fetch, a dead host and an absent plan name — four situations, three of
them actionable, one sentence for all of them. The menu bar tooltip says
**host not answering**; "backend" is not a word this product uses.

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
| `claude-status` | Claude Status | `ai` |
| `vercel` | Vercel | `devtools` |
| `git` | Git | `devtools` |
| `github` | GitHub Actions | `devtools` |
| `supabase` | Supabase | `devtools` |
| `plausible` | Plausible | `devtools` |
| `local` | Local | `devtools` |

**Extra accounts** is the user-facing name (macOS Settings section header);
"logins" and "identities" are not used. An extra account (`claude:work`) keeps
a full `title` of `Claude · Work` for
text-only surfaces (Settings, menu bar, the board). The host also ships
`label` (`Work`). Anywhere a brand mark or accent already names the tool —
dashboard tabs, rings, iPhone rows, widgets — clients draw `label` instead so
three Claude accounts do not all truncate to "Claude…".

That rule is about what is *drawn*. Spoken strings are text-only by
definition — there is no mark beside them — so VoiceOver gets the full `title`
even on those same surfaces (see [`docs/rings.md`](rings.md)). Neither string
is the id: `claude:work` is identity, and reading it aloud gives "claude colon
work".

## Source groups

Membership comes from `host/sources_config.py` (`GROUP_AI` / `GROUP_DEVTOOLS`,
served as `sources[].group`). Section titles are chrome and live in
`Shared/HeadroomCopy.swift`:

| Term | Meaning | Surfaces |
|---|---|---|
| **AI coding tools** | Claude / Codex / Cursor / Copilot / … — plan left, no key to paste; Claude Status watches status.claude.com | macOS Settings + onboarding, iOS Settings |
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
