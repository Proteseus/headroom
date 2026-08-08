# Headroom telemetry service

This is the small first-party ingestion service for the Mac's optional
anonymous diagnostics. It accepts one aggregate batch per Mac per week and
stores it in D1. It has no user accounts and no client credential.

## Deploy

Install Wrangler, create the database, put the returned id in
`wrangler.toml`, then apply the schema and deploy:

```bash
npx wrangler d1 create headroom-telemetry
npx wrangler d1 execute headroom-telemetry --remote --file=schema.sql
npx wrangler deploy
```

Existing databases need the dedupe migration before schema-2 clients can
store batches:

```bash
npx wrangler d1 execute headroom-telemetry --remote \
  --file=migrations/002_dedupe_key.sql
npx wrangler deploy
```

Schema 2 requires a week-scoped `dedupe_key` (`HMAC-SHA256` of a local install
secret and the ISO week). The Worker stores at most one row per
`(period, dedupe_key)`, so Debug/Release copies of the same Mac cannot inflate
weekly active Macs. See [`docs/telemetry.md`](../docs/telemetry.md).

The current deployed URL is
`https://headroom-telemetry.mz-508.workers.dev/v1/batches`, which matches
`HeadroomTelemetry.defaultEndpoint` in `macos/Sources/Telemetry.swift`. A
release build can override it through the `telemetryEndpoint` UserDefaults key
during local testing.

The public Community Pulse is served at
`https://headroom-telemetry.mz-508.workers.dev/community`. Its JSON source is
`/v1/community`. Only rollups meeting the minimum group size are published;
raw batches are never exposed.

## Local smoke test

The Worker has no framework dependency. Its request sanitizer can be exercised
with a small `Request` and a fake D1 binding; unknown provider, model-family,
feature, and oversized values should be discarded or rejected before storage.

The community page is intentionally read-only and open to everyone. The
aggregation code and schema live in this repository so the community can
audit, fork, or self-host the dashboard. D1 remains the private operational
store for raw aggregate batches.
