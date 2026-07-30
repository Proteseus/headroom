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
- **CHANGELOG.md.** Releases exist and the workflow already generates notes;
  a file people can read without clicking through tags is the missing half.
- **Issue templates.** One bug form that asks for host version, `/health`
  output, and which provider. Most reports will be "provider X went blank".

## Product

- **Provider fixture tests.** Every quota source parses a vendor file that can
  change without notice. Checked-in fixtures per provider would turn a silent
  blank card into a red test.
- **First-run without a provider.** Currently all three quota sources stay on
  so the UI can show sign-in errors. Someone who has none of them sees three
  errors and no explanation.
- **Board reconnect.** Wi-Fi to USB CDC failover works, but the status copy
  during the transition is thin.
