# Anonymous product diagnostics

Headroom is local-first. The Mac sends no diagnostics unless the user leaves
**Share anonymous product diagnostics** enabled in Settings → Telemetry.

The setting is on by default so we can understand which releases and provider
integrations are actually in use. It can be turned off at any time. Turning it
off deletes any pending local batch.

## What is sent

At most one aggregate batch per calendar week:

- app version, app build, bundled host version, macOS major version, and CPU
  family (`arm64` / `x86_64`);
- normalized provider ids that are enabled, used, or healthy;
- rounded model-family shares from the local usage summary;
- three coarse feature flags: phone pairing, agent gateway, and multi-Mac.

Model names are mapped locally to families such as `sonnet`, `opus`, `gpt`,
`codex`, and `other`. The raw model string never leaves the Mac.

## What is not sent

Headroom never sends prompts, commands, code, file paths, repository names,
branches, commit messages, emails, account ids, tokens, exact spend, raw model
names, or per-request activity through this system.

There is no stable install id, hardware id, serial number, Secure Enclave key,
or App Attest identity. The batch id is random and exists only to deduplicate
network retries.

The background Python host does not send telemetry. The Mac app owns consent,
builds the batch, and submits it over HTTPS. A failed telemetry request is
ignored and never affects Headroom's dashboard or host.

## Implementation

The client contract lives in
`macos/Sources/Telemetry.swift`. The first-party ingestion Worker and D1
schema live under `telemetry/`. The Worker validates and whitelists the
payload before storing it, does not persist request headers or IP addresses,
and retains raw aggregate batches for only a short operational window.

## Community Pulse

The public Community Pulse is a read-only aggregate view at the Worker’s
`/community` route. It publishes weekly active Macs, current build spread,
service adoption, model-family shares, and coarse feature adoption. It never
publishes raw rows. Any group smaller than five contributing Macs is withheld,
so the dashboard says “growing” while the community is still small.

The metric is deliberately called **weekly active Macs**, not users: the
client sends one batch per week and has no stable install identifier. The page,
JSON route, rollup schema, and styling are all open in `telemetry/`, so the
community can audit or self-host them.
