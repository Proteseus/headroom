# Backlog

What is queued, roughly in the order it earns its keep. None of it blocks a
release.

## Structural

**Split `headroom_server.py`.** 1500 lines carrying four jobs: the HTTP
handler, the `/usage` document builder, attention scoring, and the poll loop.
The handler is the piece outsiders read first and the piece least coupled to
everything else, so it moves first.

- `host/http_api.py` gets `Handler` plus the auth and permission gates. It
  already talks to the rest only through `rollup()`, `publish()`, and the
  `_refresh_*` helpers, so this is a move, not a redesign.
- `host/usage_doc.py` gets `_compute_doc`, `_flatten_*`, `_build_activity`,
  `_bodies`. This is the harder half: the flatteners reach into module state.
- `host/attention.py` gets `_build_attention` and its weights. Self-contained
  once the doc builder is out. File split only — scoring stays product policy
  (`docs/attention.md`), not a Settings surface.
- The poller and `main()` stay.

`test_contract.py` passing unchanged is the whole acceptance test. Do it in
three commits, not one.

**Split `HeadroomModels.swift`** (1489 lines). Decodables, then the computed
views over them (`focusProviders`, ring math), then the copy helpers. Same
argument as above: it is the first file a Swift contributor opens.

**`firmware/src/main.cpp`** is 2919 lines in one translation unit: panel
bring-up, Wi-Fi, USB CDC, JSON parsing, and every screen. Lower priority than
the two above because far fewer people will touch the board, but the drawing
code and the transport have no reason to share a file.

## Hygiene

- **Pin CI actions by SHA.** `@v4` and `@v5` are mutable tags. A public repo
  running on `macos-latest` with `contents: write` on the release job deserves
  pinned actions.
- **Test the Python floor.** README claims 3.9+, CI only runs 3.12. macOS 14
  ships 3.9.6, so the claim is load-bearing for the bundled host. Add 3.9 to
  the matrix.
- **Issue templates.** One bug form that asks for host version, `/health`
  output, and which provider. Most reports will be "provider X went blank".

## Contract and access

Written up in [contract.md](contract.md), [trust.md](trust.md) and
[product.md](product.md). The docs landed first on purpose — each of these is a
separate release, and the rule each one implements is now stated somewhere the
next person can find it.

- **Show the contract mismatch.** `contract` now ships in `/usage`, `/health`
  and the board projection, and `UsageSnapshot.contractSatisfied` answers the
  question — but nothing draws the answer yet. The field had to exist before it
  could be useful, which is why it landed first. What is left is the banner on
  the phone and the Mac, with copy naming the version to update to.
- **Generate the mirrored constants.** `MAX_DEPLOYS` / `MAX_COMMITS` /
  `MAX_SERVERS` / `MAX_SOURCES` / `MAX_PROVIDERS` / `MAX_POOLS` / `FOCUS_LIMIT`
  exist twice, in two languages, kept in step by a comment. One `contract.json`
  emitting a firmware header, a Swift file and a Python module. `boot_max.h`
  and the `HostVersion` golden vector are the two precedents already in the
  repo.
- **Audit the non-optional Swift fields.** 39 decoded fields in
  `HeadroomModels.swift` are non-optional; nine are on the `/usage` path, which
  decodes all-or-nothing under one `try`. Any the host could plausibly stop
  emitting should be optional with a default at the use site.
- **Decide the transport for `agents`.** Approving a command that runs on the
  Mac currently rides a plaintext bearer token with Face ID enforced only by
  the client. Three options ranked in [trust.md](trust.md); the cheapest is one
  predicate restricting the scope to loopback + Tailscale.
- **A clear-history control.** The ledger now prunes at 30 days
  (`agent_events.RETENTION_S`), which was the urgent half. The remaining half
  is a button — deleting a SQLite file with the host stopped is not a thing to
  ask of anyone, and it is the natural home for a "forget this session" too.
- **Export and import history.** A new Mac currently costs you every chart.
  Consolidating the time series into the SQLite that already exists is what
  turns this from a project into a feature. See
  [product.md](product.md#history-is-a-user-asset).

## Product

- **Provider fixture tests.** Every quota source parses a vendor file that can
  change without notice. Checked-in fixtures per provider would turn a silent
  blank card into a red test.
- **First-run without a provider.** Currently all three quota sources stay on
  so the UI can show sign-in errors. Someone who has none of them sees three
  errors and no explanation.
- **Board reconnect.** Wi-Fi to USB CDC failover works, but the status copy
  during the transition is thin.
