# What a Swift host would look like

A study, not a plan. The question is narrow: **if `host/` were Swift instead of
Python, what would it actually be?** Not whether to merge it into the menu bar
app — that stays a separate process either way, because the ESP32 and the iPhone
poll it whether or not `Headroom.app` is running.

Scope is macOS only. No Linux, Windows, or Android target is assumed, which
removes the one argument that would otherwise favour keeping Python.

## What the host is today

7,830 lines of stdlib-only Python (plus 2,670 lines of tests), in four jobs.

| Job | Modules | Lines |
|---|---|---|
| **Serve** | `headroom_server.py` (HTTP, routing, cache, poll loop), `auth.py`, `usb_bridge.py`, `device_view.py` | ~2,040 |
| **Scrape** | `oauth_usage`, `codex_usage`, `cursor_usage`, `github_actions`, `vercel_builds`, `supabase_usage`, `plausible_usage`, `posthog_usage`, `claude_status`, `local_servers`, `git_activity`, `detect_sources` | ~3,290 |
| **Aggregate** | `burndown`, `quota_samples`, `claude_history`, `daily_burn`, `pricing`, `quota` | ~1,550 |
| **Persist / plumb** | `sources_config`, `app_config`, `cache_util`, `keychain`, `host_version` | ~950 |

The split matters because the four jobs port with wildly different difficulty.
Aggregation is pure functions over numbers and would port almost mechanically.
Scraping is where a rewrite goes to die.

## Job by job

### Serve — mostly better in Swift

`ThreadingHTTPServer` with 4 GET routes and 6 POST routes, a byte cache rebuilt
once per poll tick, and a token gate. In Swift this is `NWListener` plus
hand-rolled HTTP/1.1, or SwiftNIO as a dependency.

- **Hand-rolled on Network.framework**: ~400–600 lines to do properly — request
  line and header parsing, `Content-Length` bodies, keep-alive, read timeouts,
  connection caps, 413/414 limits. It is the single riskiest file in the port,
  because it is the only LAN-exposed attack surface and Python's `http.server`
  currently handles those edge cases for free.
- **SwiftNIO**: battle-tested, but a dependency in a repo that is deliberately
  zero-dependency, and it drags in swift-collections and friends.

Two things get strictly better:

- **Bonjour.** `_advertise_bonjour()` currently shells out to `/usr/bin/dns-sd`
  and holds a `Popen` handle ([headroom_server.py:64](../host/headroom_server.py#L64)).
  `NWListener.service` publishes `_headroom._tcp` natively. Subprocess gone.
- **Keychain.** `keychain.py` is 135 lines of `ctypes` against Security.framework
  because `security add-generic-password -w` leaks the secret into the process
  table. In Swift that's a `SecItemAdd` call. The whole file evaporates.

`usb_bridge.py` (termios, `select`, framed `HR` protocol over `/dev/cu.*`) ports
to POSIX calls from Swift roughly 1:1 — same ugliness, different syntax. No win,
no loss.

### Scrape — where the real cost is

Ten modules whose entire job is coping with third-party JSON that nobody
documents and that changes without notice: Anthropic OAuth, OpenAI's
`wham/usage`, Cursor's `GetCurrentPeriodUsage` (read out of a **SQLite**
`state.vscdb`), the GitHub, Vercel, Supabase, Plausible, and PostHog APIs, plus `lsof`,
`git`, and `gh` subprocess output.

Python's forgiving `data.get("a", {}).get("b")` is not incidental here. It is
the reason a provider changing a key degrades one row instead of killing the
source. Swift's `Codable` is the opposite temperament: a decode either produces
the declared type or throws.

**This is the design decision that decides whether the port succeeds.** Two
options:

1. **All-optional `Codable` structs per response.** Verbose, but the compiler
   tells you what the code assumes. Roughly what `Shared/HeadroomModels.swift`
   already does for the wire format.
2. **A small `JSONValue` enum** (~120 lines, written once) with subscript sugar,
   so scrapers keep reading `json["usage"]["limits"][0]["percent"]?.double`
   exactly as forgivingly as today.

The honest answer is both: `JSONValue` at the edge where the shape is unknown
and volatile, typed structs the moment the data crosses into aggregation. Going
all-in on `Codable` at the boundary will produce a host that is more brittle
against upstream drift than the Python one, which defeats the point.

Mechanical substitutions, all stdlib/SDK, no dependencies:

| Python | Swift |
|---|---|
| `urllib.request` | `URLSession` |
| `sqlite3` (Cursor) | `import SQLite3` (C API, in the SDK) |
| `subprocess` (`git`, `gh`, `lsof`, `security`) | `Process` |
| `concurrent.futures.ThreadPoolExecutor` | `TaskGroup` |
| `threading.Lock` around `_cache` | `actor` |
| `zoneinfo` | `TimeZone` / `Calendar` |
| `ctypes` → Security.framework | native `SecItem*` |

### Aggregate — ports cleanly

`burndown.py`, `quota_samples.py`, `claude_history.py`, `daily_burn.py` are
arithmetic over timestamps, percentages, and token counts, already written as
pure functions with fixture-driven tests. They port near-mechanically, and the
1,550 lines are the best-tested in the repo.

One thing to watch: `claude_history` and the server's minute buckets do
incremental reads by remembering byte offsets per file
(`_offsets`, [headroom_server.py:94](../host/headroom_server.py#L94)) across a
~600MB JSONL tree. Swift needs `FileHandle` + manual newline splitting, and
per-line `JSONDecoder` is meaningfully slower than Python's `json.loads` in a
tight loop. `JSONSerialization` is closer. Worth measuring on a real
`~/.claude/projects` before assuming the port is free.

### Persist — a wash

Config and sample stores are JSON files with atomic-rename writes
(`cache_util.py`, 66 lines). Identical in Swift.

## The prize

The strongest argument for a Swift host is not `/usr/bin/python3` risk. It's
this: **the wire format would have exactly one definition.**

Today the `/usage` document is written down three times — Python dicts in the
host, Codable structs in `Shared/HeadroomModels.swift`, field reads in
`firmware/src/main.cpp` — and only contract tests keep them honest
([host/test_contract.py](../host/test_contract.py),
[macos/Tests/ContractTests.swift](../macos/Tests/ContractTests.swift)). Those
tests exist because renaming a key used to be a silent break.

A Swift host **encodes the same structs the macOS and iOS apps decode**. Rename
a field and three targets fail to compile. The contract tests shrink to covering
the one client that can't share types: the C++ firmware.

Secondary wins: no `/usr/bin/python3` dependency (a Command Line Tools shim
Apple keeps signalling it wants gone), no `PATH` juggling in the LaunchAgent
plist, one language for the whole repo, and `SMAppService.agent(plistName:)`
instead of hand-writing `~/Library/LaunchAgents/com.centaur-labs.headroom.plist` — which
also gives the user a real toggle in System Settings → Login Items.

## The tax

- **Iteration speed.** Editing a scraper and re-running its tests is under a
  second today. In Swift it is a rebuild. The scrapers are the part of this
  project that changes most often, because providers change formats.
- **No hotfix-in-place.** A `.py` inside the app bundle can be patched by hand
  when Cursor ships a schema change on a Friday. A compiled binary can't.
- **Swift 6 strict concurrency** is on for this repo. Ten pollers sharing a
  cache is exactly the shape the compiler is most opinionated about. Actors are
  the right answer and also a real porting cost.
- **Test mocking.** Python monkeypatches `urllib.request` in a line. Swift needs
  `URLSession` injected behind a protocol in every scraper. Doable — most are
  already function-shaped — but it touches all ten.
- **Notarization.** A separate compiled helper inside the bundle needs its own
  signing story, and is architecture-specific where a `.py` was not.

## Migration path

Big-bang rewrite is the failure mode. The strangler order below is deliberately
risk-first: prove the scary layer early, port the well-tested arithmetic last.

**Phase 0 — freeze the contract.** Done: contract tests both sides, plus the
`/health` version handshake (`host/host_version.py`,
`macos/Sources/HostVersion.swift`), so a running host can always be identified.

**Phase 1 — Swift host skeleton, no scrapers.** HTTP server, routing, auth,
Bonjour, config, byte cache, `/health`. Every source **proxies to the Python
host** on another port. Ship behind a flag, run it for a week. This tests the
riskiest component (hand-rolled HTTP, launchd lifecycle) with zero scraper risk,
and it is cheap to abandon if the server layer turns out to be miserable.

**Phase 2 — port scrapers one at a time,** each behind a per-source switch, each
verified by a `scripts/diff-hosts.sh` that pulls `/usage` from both hosts on the
same machine and diffs the JSON. Start with the simplest (`local_servers`,
`git_activity`), finish with the nastiest (`cursor_usage`, `oauth_usage`).

**Phase 3 — port the aggregation core.** `quota_samples`, `burndown`,
`claude_history`, `daily_burn`. Port their fixtures verbatim so the XCTest suite
asserts the same numbers the Python suite does.

**Phase 4 — drop Python.** Remove the embedded host, switch the LaunchAgent to
`SMAppService`, delete the `/usr/bin/python3` probing in
`macos/Sources/HostController.swift`.

The one rule: never sit in a half-and-half state for long. Two runtimes where
both are required is worse than either endpoint.

## Effort

Rough, for someone who already knows this code:

| Phase | Estimate | Confidence |
|---|---|---|
| 1 — server skeleton + proxy | 2–3 days | medium |
| 2 — ten scrapers | 4–7 days | low (long tail; upstream shapes are the unknown) |
| 3 — aggregation core | 3–4 days | high (well tested, pure functions) |
| 4 — cutover, SMAppService, docs | 1–2 days | high |

Call it 10–16 focused days, and expect Phase 2 to be where the estimate breaks.
Output would be roughly 10–13k lines of Swift for today's 7.5k of Python.

## Recommendation

Worth doing, for the single-source-of-truth wire format more than for anything
else. Not worth doing as a rewrite, and not worth starting with the fun part.

Do Phase 1 as a spike first and judge the hand-rolled HTTP layer on the evidence.
If that layer feels bad after a week of running it, the whole project is a no,
and you've spent two days finding out instead of two weeks.

And note what this does **not** change: the host stays a separate process with
its own lifecycle. A Swift host makes it *possible* to later run the same code
in-process while the app is up and as a daemon when it isn't — but that's a
different decision, and it needs the same answer to "what serves the ESP32 at
3am when the menu bar is quit?"
