# Anonymous product diagnostics

Headroom is local-first. The Mac sends no diagnostics unless the user leaves
**Share anonymous product diagnostics** enabled in Settings → Telemetry.

The setting is on by default so we can understand which releases and provider
integrations are actually in use. It can be turned off at any time. Turning it
off deletes any pending local batch. The local install secret is kept so
toggling the setting cannot mint a fresh weekly identity.

## What is sent

At most one aggregate batch per calendar week:

- app version, app build, bundled host version, macOS major version, and CPU
  family (`arm64` / `x86_64`);
- normalized provider ids that are enabled, used, or healthy;
- rounded model-family shares from the local usage summary;
- three coarse feature flags: phone pairing, agent gateway, and multi-Mac;
- a **week-scoped dedupe key** (`HMAC-SHA256(install_secret, ISO week)` as
  64 hex chars) so the intake can ignore duplicate reports from the same Mac
  in the same week.

Model names are mapped locally to families such as `sonnet`, `opus`, `gpt`,
`codex`, and `other`. The raw model string never leaves the Mac.

## What is not sent

Headroom never sends prompts, commands, code, file paths, repository names,
branches, commit messages, emails, account ids, tokens, exact spend, raw model
names, or per-request activity through this system.

There is no stable install id, hardware id, serial number, Secure Enclave key,
or App Attest identity. The install secret stays on the Mac (Keychain +
`~/.headroom/telemetry/install_secret`). Only the week-scoped HMAC leaves, and
it changes every ISO week, so the server cannot stitch a long-lived install
history. The random `batch_id` only deduplicates network retries of the same
payload.

The background Python host does not send telemetry. The Mac app owns consent,
builds the batch, and submits it over HTTPS. A failed telemetry request is
ignored and never affects Headroom's dashboard or host.

## Deduping weekly active Macs

The Worker stores at most one row per `(period, dedupe_key)`. A second batch
from the same Mac in the same week — Debug rebuild, Release copy, or a retried
POST with a new `batch_id` — is accepted as `ok` but does not increment the
rollup. Turning diagnostics off and on does not rotate the secret. Deleting
both Keychain and `~/.headroom/telemetry/install_secret` would, which is the
same class of local wipe as reinstalling.

The metric remains **weekly active Macs**, not users: two Macs are two
reports, by design.

## Implementation

Schema **2**. The client contract lives in
`macos/Sources/Telemetry.swift`. The first-party ingestion Worker and D1
schema live under `telemetry/`. The Worker validates and whitelists the
payload before storing it, does not persist request headers or IP addresses,
and retains raw aggregate batches for only a short operational window.

At ingest the Worker reads Cloudflare’s edge `request.cf.country` (ISO-3166
alpha-2) and stores that code on the batch row. The IP itself is never written
to D1, logs, or the published payload. Unknown / Tor (`XX`, `T1`) stay null.

Existing D1 databases need migrations once:

```bash
npx wrangler d1 execute headroom-telemetry --remote \
  --file=telemetry/migrations/002_dedupe_key.sql
npx wrangler d1 execute headroom-telemetry --remote \
  --file=telemetry/migrations/003_country.sql
```

## Community Pulse

The public Community Pulse is a read-only aggregate view at the Worker’s
`/community` route. It publishes:

- weekly active Macs across the retention window (empty and sub-threshold
  weeks stay on the axis as withheld);
- build spread / version distribution against the current update-feed release
  (`X.Y.Z` only, capped at that release — junk and ahead-of-feed builds stay out);
- CPU architecture, macOS major version, and country mix (edge geo codes);
- service adoption in three lanes — enabled, used, and healthy;
- model-family shares and coarse feature adoption.

It never publishes raw rows. Empty groups stay withheld; any group with at
least one contributing Mac is published. The floor used to be five while the
community was still tiny; it is one now so early signal shows.

The page, JSON route, rollup schema, and styling are all open in `telemetry/`,
so the community can audit or self-host them.
