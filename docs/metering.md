# Metering: plans, balances, and bills

How Headroom should model paid API usage alongside the subscription plans it
already watches. [docs/product.md](product.md) covers what to build,
[docs/contract.md](contract.md) covers shape, [docs/trust.md](trust.md) covers
access. This file covers **what a meter is**, because Headroom currently knows
about exactly one kind and the world has four.

## The one abstraction, and what it does not cover

Every quota source in the registry is a `PoolSpec`: a percentage of an opaque
pool that resets on a clock. Rings, pace, burndown, daily burn, the menu-bar
tanks and the board's three slots are all built on that one shape
([docs/rings.md](rings.md)).

It is a good abstraction. It covers one of the four ways people actually pay
for this stuff.

| Meter | Unit | Resets | Who | In Headroom |
|---|---|---|---|---|
| **Plan window** | % of an opaque pool | on a rolling or calendar clock | Claude Max, Codex, Cursor, Copilot, Gemini, Windsurf, JetBrains, Zed | ✅ this is the whole app |
| **Prepaid balance** | dollars remaining | **never** — it only goes down until you top up | Anthropic Console credits, OpenAI credits, OpenRouter, Together, Groq, Fireworks | ❌ no model at all |
| **Postpaid bill** | dollars accrued | calendar month | Anthropic/OpenAI postpaid orgs, Bedrock, Vertex, Foundry | ⚠️ half — see below |
| **Rate limit** | requests and tokens per minute | every minute | every API, every tier | ❌ and deliberately so |

The postpaid row is half-done and worth looking at, because it shows the
pattern. `codex_usage._parse_spend_control` and `cursor_usage._on_demand`
already produce `used_usd` / `limit_usd` / `remaining_usd`, and
`headroom_server.py` flattens them into `cost_usd`, `cost_limit_usd`,
`cost_remaining_usd`, `cost_reached`. So the host already carries money. It
carries it as loose extra keys hanging off two provider payloads, not as a
meter — which means it gets no ring, no burndown, no pace, no history, and no
attention rollup. Money is a second-class citizen in a document that is
otherwise entirely about metering.

**A balance is the case that breaks things**, and it breaks them at the
abstraction rather than at the UI. A balance has no window, so `resets_in_s` is
undefined, so `pace_pct` is undefined, so the burndown's "where an even spend
would put you" is undefined. Three of the four numbers on a ring stop meaning
anything. That is not a rendering problem to paper over; it is the model
telling you a balance is a different kind of thing.

## The other ways people track this today

Worth writing down, because each one is a feature request in disguise and
Headroom is already better positioned for some than for others.

- **A browser tab pinned to the billing console**, refreshed nervously. This is
  the behaviour Headroom exists to delete, and it is the strongest argument for
  balances: a plan quota resets and forgives you, a prepaid balance hits zero
  and stops your agent mid-turn.
- **`ccusage` and friends in a terminal split** — parse `~/.claude` JSONL,
  print today's spend. `host/claude_history.py` already does this, with 400
  days of retention and per-model breakdown, and surfaces almost none of it.
  This is the biggest gap between what Headroom knows and what it says.
- **A spreadsheet, updated monthly**, usually because someone has to expense it.
  This is an export feature, not a display feature. See Retention below.
- **The monthly credit-card surprise.** No tooling at all. The people in this
  group don't want a chart, they want one number and a threshold.
- **A billing webhook into Slack.** Push, not poll — and out of scope while the
  host is stdlib-only ([docs/product.md](product.md#stdlib-only-and-when-that-ends)).

Two of those five are things Headroom already computes and hides. Start there.

## Decisions

### 1. A pool gains a reset discriminator. It does not gain a second kind.

`PoolSpec` gets `reset`, one of:

| `reset` | Meaning | Countdown | Pace |
|---|---|---|---|
| `window` | rolling window, current behaviour | `resets_in_s` | yes |
| `calendar` | resets at a month/day boundary | `resets_in_s` | yes |
| `none` | a balance; depletes and stays depleted | **null** | **null**, replaced by runway |

Additive, one field, and every downstream consumer branches on it once instead
of guessing from whether `resets_in_s` happened to be null. The alternative —
a parallel `balance` meter kind next to `quota` — duplicates the sampler, the
burndown, the daily-burn rollup and the flatteners, and those would drift.

A `reset: none` pool reports **runway**: days remaining at the trailing burn
rate, computed from the samples already being stored. Runway is to a balance
what pace is to a window: the number that turns a level into a warning.

### 2. A balance does not get a ring.

Ring and pace semantics are a cross-platform contract — `docs/rings.md`,
`Shared/HeadroomRings.swift` and the firmware constants move together or not at
all. Stretching "% of this window remaining" to cover "dollars left, no window"
means editing that contract in three languages to express something it was not
built to say.

Don't. A balance is a depletion bar with a runway date under it. That is a new
component on the Mac and the phone, and it is cheaper than renegotiating the
ring across three codebases and a firmware deprecation window.

The rings keep meaning exactly what they mean today. That is the point.

### 3. Estimated dollars and billed dollars are different kinds of number.

This is the trust decision and it is the one that matters most.

`pricing.py` turns local token counts into USD. `quota.py` is explicit that the
result is a compute-weighted proxy against a budget *you* set, not money. That
is honest as long as nothing prints a dollar sign next to it.

The moment a card says **$14.20 spent today**, the user compares it to the
console bill. When the two disagree — and they will, because of tier discounts,
intro pricing, batch rates, cache accounting and rounding — the app is wrong
about money, which is a different category of wrong from being wrong about a
percentage.

So:

- A number Headroom computed from local token counts is **estimated** and is
  labelled as such at every surface that shows it.
- A number a provider reported is **billed** and is labelled as such.
- **The two are never summed into one figure.** A total that mixes them is a
  number with no meaning and no way to check.

This is the same instinct as `_held_resets(trusted=False)` in
`headroom_server.py`: a stale countdown is the most convincing wrong number in
the document, so it is withheld rather than shown. An unlabelled estimate is
the money version of that, and it is worse, because nobody audits a percentage
against a credit-card statement.

### 4. The price table is now load-bearing, and it was wrong.

`host/pricing.py` had no entry for `claude-opus-5`. `_base()` falls through to
`_DEFAULT`, which is Sonnet-tier, so every Opus 5 record was priced at
**$3/$15 instead of $5/$25** — about 40% under. On this machine that is 13,185
assistant records across the local history, and it has been flowing into
`cost_usd`, daily burn, the spend card and the 400-day history the whole time.
`claude-mythos-5` had the same problem at $10/$50. Both rows are added.

`RATES_CHECKED` is deliberately not bumped: rows were added, nothing was
re-verified against a fresh catalog read.

Two follow-ons, neither done yet:

- **The fallback is silent.** Pricing an unknown model at Sonnet rates is
  better than pricing it at zero, but it produces a confident wrong number with
  no tell. Records priced by fallback should be marked, so the UI can say
  *estimated, unrecognized model* instead of just a dollar amount.
- **An unknown model id is an attention reason.** A new model shipping is
  exactly the event that makes this table stale, and noticing that something
  changed is the job Headroom already does. This is the cheapest possible
  guard against silently drifting prices, and it costs one entry in the
  attention rollup ([docs/attention.md](attention.md)).

The intro-pricing comment on `claude-sonnet-5` is a third case: a per-account
fact hardcoded as a global. Whoever qualifies for intro pricing gets a number
that is right; whoever doesn't gets one that is quietly 50% high. Leave it as a
comment until someone asks, then it is a per-account setting, not a table edit.

### 5. API sources need a pasted key, and that changes where they live.

The README splits sources two ways: **AI coding tools** are read from a sign-in
already on the Mac, with nothing to paste; **dev tools** want a key. An API
account is "how much money is left" — unmistakably an AI coding tool by that
description — and it needs a pasted key. The split conflates two independent
axes.

Make them independent:

| Axis | Values |
|---|---|
| Setup | local sign-in \| pasted key |
| Meter | plan \| balance \| bill |

An API source is `group="ai"` with a `needs_key` flag, not a third group. The
group is about what the thing *is*; setup is a property, not a category.

Access follows [docs/trust.md](trust.md) with no new rules: a key is a
credential, so it is **Mac-local** — Keychain, pasted in Mac Settings, never
written into `/usage`, never offered to the phone. Same treatment as the
GitHub, Supabase and Plausible keys.

One thing does deserve a new sentence in `SECURITY.md`: **an org-level usage or
admin API key is a much larger credential than a stats key.** It reads spend
across every member and project, and on some providers the same key class can
do more than read. Prefer the narrowest read-only scope a provider offers, and
say plainly in the UI what the key can see. A Plausible key leaks visitor
counts. An admin key leaks the shape of the whole company's AI spend.

### 6. Rate limits are the fourth meter and Headroom should not build them.

"Am I about to get 429'd" is genuinely the Headroom question, asked at a
one-minute timescale instead of a one-week one. It is tempting.

It does not fit, for a structural reason: **RPM/ITPM/OTPM state lives in the
response headers of requests Headroom does not make.** Headroom is an observer
— it reads files other tools left on the disk. To know the live limit state it
would have to either proxy the traffic (it is not in that path and should not
be) or fire a probe request, which means spending money to measure spending.

So: **not built, and this is why**, so it stops being re-argued. The one
carve-out: if a provider's usage endpoint happens to return current limit state
alongside the spend numbers, take it as data. Don't go making calls to find it.

### 7. Extra accounts already generalize. This is the cheap part.

`accounts.py` plus `account_kind` already expand one registry row into N, each
with its own poll, samples, burndown, ring, colour and pinned order. An API
account is exactly that shape: a label plus a credential location. `claude:work`
becomes `anthropic-api:prod`.

Everything downstream — focus-3, the board's slots, colour overrides,
reordering, per-account history — comes free. This is the strongest evidence
that the registry design is right, and it means the expensive part of adding
API sources is the meter semantics, not the plumbing.

### 8. Money lands on the Mac and the phone first. The board waits.

`MAX_PROVIDERS`, `MAX_POOLS` and `FOCUS_LIMIT` are all 3, mirrored into the
firmware by a comment ([docs/contract.md](contract.md)). Money on the board
means new labels, new caps, and a reflash — and per contract.md the board's
deprecation window is "until the shim costs more than a kilobyte," which is to
say years.

Ship money where the client updates in days, learn what the numbers should say,
and only then spend a firmware revision on it. Same shape as the standing rule
that the board never gains agent controls: the board is a render target, and it
should render a settled idea.

### 9. Balances resolve product.md's open question.

[docs/product.md](product.md#the-unresolved-one-whose-quota-is-it) leaves one
question open: is the burndown chart *"what this Mac watched happen"* or
*"what happened to this pool"*? For a plan quota it is genuinely ambiguous.

For a balance it is not. A credit balance is one global number that both Macs
observe and either can spend against. There is no reading in which two Macs
have separate balances. Adding balances therefore **forces the second answer**
— the chart is what happened to the pool, with machine identity as provenance
rather than ownership.

That is the answer product.md guessed was right. Adding a balance source is
what makes it no longer a guess, and it should be decided before the multi-Mac
merge, not after.

### 10. Retention and export stop being optional.

product.md already calls export "the gap most worth closing." Money makes it
sharper in two directions:

- **Spend history is worth more than percentage history.** A year of "how much
  did this cost" is the thing someone has to expense, reconcile, or justify. A
  new Mac currently costs you all of it.
- **Spend history is more sensitive than percentage history.** `docs/privacy.md`
  currently describes quota samples. A per-model, per-day cost record is a
  finer-grained picture of what someone was doing and how hard. It needs its
  own line in the privacy doc before it ships, not after.

CSV export of daily cost is also the cheapest possible answer to the
spreadsheet crowd from the survey above, and it needs no new UI beyond a
button.

## What earns a Setting here

Applying product.md's rule — a preference exists when two reasonable people
using Headroom the same correct way need different values:

| Value | Where | Why |
|---|---|---|
| Which API accounts exist, and their keys | Settings | a fact about your setup |
| Monthly budget target | Settings | genuinely differs per person; nothing can derive it |
| "Make this balance last until *date*" | Settings | a personal intention, not a fact |
| Runway thresholds (when a balance turns amber) | **hardcoded** | a judgment we made |
| Whether estimated and billed are labelled | **hardcoded** | not a preference, an invariant |
| Poll interval for a spend endpoint | **hardcoded** | a tradeoff with a right answer |

No Spend Settings pane. If a threshold is wrong, our number is wrong.

## Order of work

Each row is a release, and each one is useful on its own.

| # | What | Why it is first / next |
|---|---|---|
| 0 | Price table fix; mark fallback-priced records; label estimates as estimated; unknown-model attention reason | No new sources, no contract change, and it stops the app being confidently wrong about money it already displays |
| 1 | Surface `claude_history` cost that already exists — today, this week, by model | The single largest gap between what the host knows and what it says. Still no new sources |
| 2 | `PoolSpec.reset` in the contract, plus runway on the host | Additive, no UI, lets one client at a time catch up |
| 3 | One API source end to end — balance and month-to-date cost, Keychain key, one account per key | The proof. Pick the provider whose numbers you can check against a console by hand |
| 4 | A second provider | The only real test of whether the abstraction held |
| 5 | CSV export of daily cost | Closes the retention gap while the data is still small |
| 6 | The board, if the semantics have settled | Last, because it is the one that cannot be taken back cheaply |

Deliberately not on this list: rate limits (decision 6), a spend Settings pane
(above), summing estimated and billed (decision 3), and stretching the ring to
cover balances (decision 2).
