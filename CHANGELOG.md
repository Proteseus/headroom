# Changelog

Marketing versions come from [`host/VERSION`](host/VERSION); every entry below
is a `v`-prefixed git tag. Apple build numbers (`git rev-list --count HEAD`)
are not tracked here because they move on every commit.

Add a section here before cutting a tag. `scripts/cut-release.sh` refuses to
tag a version that has no entry.

## 1.2.6 — 2026-07-30

### Changed

- iPhone drops to three tabs. Quotas and Settings both leave the bar: quota
  detail is reached from Overview, where the rings already are, and Settings
  becomes a toolbar button on every tab instead of a destination competing with
  the data. Five tabs for four screens and a preferences pane was one bar doing
  two jobs.
- The Mac app icon sits on Apple's icon grid — a rounded 824-of-1024 tile with
  clear margins, no baked shadow — instead of a full-bleed square. macOS masks
  nothing for you, so the Dock was drawing a black rectangle among rounded
  ones. iPhone, Watch and the App Store PNG are unchanged: those masks come
  from the system, and App Store Connect rejects alpha.
- The Welcome window's **On your phone** pane shows the mobile token itself,
  with a Copy button, instead of sending you to Settings to fetch it — a detour
  on the one screen whose whole job is getting the phone paired. If the host
  has not written the token yet the pane says so and offers to look again.
- `scripts/update-app.sh` closes the app up front and defaults its prompt to
  yes.

### Fixed

- The ESP32 sealed its panel edge in a fixed colour, so every cold-blue boot
  frame got a warm strip along the bottom, repainted each splash frame while
  the picture above it rolled. It read as the bottom of the panel
  misbehaving. The canvas now seals to whatever colour it last cleared to, and
  `scripts/render_esp32_preview.py` mirrors the seal so previews stop promising
  pixels the panel eats.
- The ESP32 quota page reclaimed 22px it was reserving for page dots nothing
  draws, which had left 50px of nothing under the chart against 28 above the
  header.

## 1.2.5 — 2026-07-30

### Added

- Coding-agent approvals show the agent's actual request. Every field the
  provider sent is listed in reading order with its own label — an `Edit` shows
  the file, the text being replaced and the replacement, tinted so the pair
  reads as a before and after. Bulk fields sit behind **Show request** so the
  feed stays scannable.
- **Why** carries Claude's own stated reasons for asking.
- A value the host had to clip says **Shortened to fit**, and dropped fields
  are counted, so a prefix of a command is never mistaken for the whole one.
- Each agent row says how long it has been waiting — same words and placement
  as an activity row's age, because they are two halves of one feed. A request
  that has sat for six minutes reads very differently from one that just
  arrived, and the permission hook gives up at around five.
- A third answer, **Always allow this exact request**, saves a permission rule
  so Claude stops asking. Headroom writes only the exact command or path it
  showed you — Claude's own "Yes, don't ask again" widens a command to a
  prefix, and a grant made from a phone outlives the request that prompted it.
  The row prints the rule under the buttons before you tap, and glob
  characters in paths are escaped so a folder named `[2024-06] Reports` cannot
  match its siblings. Questions are never offered it.
- Each row carries the agent's own mark in its brand colour instead of one
  generic speech bubble, so a Claude row and a Codex row stop looking alike.
- Notices that can only be dismissed can be swiped away. Rows carrying a real
  answer cannot: a swipe that denied a permission would send Claude a decision
  by accident.
- **You can answer Claude's questions from the phone.** Its options become the
  buttons, and tapping one sends the choice back so Claude carries on without
  you touching the Mac. No hook can hand `AskUserQuestion` a selection — but a
  denied `PreToolUse` call is documented to show Claude the reason, so the
  choice travels as the reason. It is a workaround and behaves like one:
  Claude sees a blocked tool plus your words rather than a clean result, so it
  may occasionally acknowledge the block. Headroom answers only a single
  question of two to six options, never a `multiSelect` one, and everything
  else — a timeout, an odd shape, or **Ask on Mac** — defers, which leaves the
  question to appear on the Mac exactly as before. See
  `docs/agent-attention.md`.
- Installed hooks are now version 2, adding a `PreToolUse` entry scoped to
  `AskUserQuestion`. Settings reports **Outdated** until you reinstall them.

### Fixed

- An `AskUserQuestion` row is readable. Claude's questions arrive through the
  permission hook, and the nested `questions` array reached the phone as a wall
  of raw JSON — the question was in there, but nobody was going to find it. The
  row now leads with the question itself instead of "Use AskUserQuestion", and
  each option is one control carrying the reason you would pick it. The first
  pass listed the descriptions above a row of buttons repeating the same
  labels, which said everything twice.
- Answer buttons take the account's accent instead of the system blue, so they
  belong to the agent that asked. Short answers stay bordered pills; a
  question's options are sentences with a reason under each, and tinting those
  turned every one into a large coloured slab. They read as plain rows with a
  divider and a chevron now — the shape a grouped list uses everywhere else on
  the system — with the colour on the chevron. **Ask on Mac** sits below the
  divider rather than among the answers, because it is the way out rather than
  another option.
- The provider mark moved to the top-right corner of an agent row. Which agent
  asked is a property of the row, not the first thing to read in the sentence.
- **Claude finished responding** no longer stacks. A session's finished or idle
  notice replaces the one it makes untrue, so the feed carries at most one per
  session instead of a wall of identical rows burying the approvals that
  actually want an answer. Superseding is scoped by session and kind, so a
  notice arriving can never close a permission request you have not answered.

### Changed

- The phone used to decode four fields of a request and drop the rest, which
  made an `Edit` approval read as "Use Edit" and a `Write` show a path but
  never the content. `detail.request` now carries typed fields end to end; an
  unrecognised tool renders without an app update.
- The Claude adapter reads `permission_reasons` (the documented field) as well
  as the older `permission_suggestions`, and keeps `tool_use_id` / `prompt_id`
  for correlation.
- `docs/agent-attention.md` corrects its claim that structured questions are
  notify-only pending provider support. Against Claude Code 2.1.220 the
  `Elicitation` hook returns real form values, `updatedPermissions` makes
  "always allow" answerable, and `decision.interrupt` exists — all four are
  wiring gaps on our side, now written down as such.

## 1.2.4 — 2026-07-30

### Added

- `scripts/update-app.sh` installs the latest notarized Release from the
  command line. This landed on `main` ahead of the bump and ships here rather
  than in a release of its own.

### Changed

- iOS Overview **Connected** tile names the Mac and its address (Computer
  Name · host / IP), not just the last update time. Settings → Connection
  shows the same split.
- Watch Overall burndown lines are fully opaque, matching the ESP32 glance.
  The binding source stays thicker; context sources no longer fade.
- Mac Settings moves the Dashboard row limits out of General and in beside the
  integrations whose rows they count.
- `docs/attention.md` writes down what Attention scoring is: hardcoded product
  policy, deliberately not a Settings pane. The README and CONTRIBUTING build
  instructions also stop being wrong about XcodeGen being optional and about
  `-sdk iphonesimulator` on the iPhone target.

### Fixed

- A source whose login has gone now says **Needs sign-in** instead of **Not
  updating**, and says it on the card, in Settings, and in Attention. The host
  ships `auth_required` next to `stale`, so a dead credential is no longer
  indistinguishable from a rate limit or a dropped network.
- Quota cards show the host's error whenever there is one. The message was
  gated on `ok`, which the host deliberately keeps true while it replays the
  last good bars — so the failures that had a reason worth reading were exactly
  the ones that hid it. A missing Claude token reported eleven hours of frozen
  numbers without ever surfacing the `claude login` it was asking for.
- Attention calls out a missing login immediately rather than waiting out the
  fifteen-minute stale threshold. Waiting does not fix a login.
- The ESP32 corner glyph marks a frozen reading, not just a dropped cable. It
  was gated on whether the Mac answered, so the case that lasts — the Mac
  replying every ten seconds about numbers it has been unable to refresh since
  last night — drew nothing at all. Ages now read `42m` / `11h` / `3d`, and a
  dead login is prefixed `!`.

## 1.2.3 — 2026-07-30

### Fixed

- Multi-Mac over iCloud actually connects. The signed app declared the iCloud
  container but carried no application identity to bind it to, so CloudKit
  refused every request with "Trying to initialize a container without an
  application ID". Releases now take the application identifier, team and
  container environment from the provisioning profile, the way Xcode does when
  it signs. 1.2.2 looked correct by every check available and never wrote a
  single record.

## 1.2.2 — 2026-07-30

### Fixed

- Multi-Mac says why it is not syncing. A CloudKit round that failed was
  discarded without a word, and the host's trouble text only ever described the
  folder transport, so every failure showed up as "No other Macs yet" — the
  same words a healthy sync with nobody else on it produces. A missing record
  type, a signed-out iCloud account and an unreachable network now each say so.
- The CloudKit schema ships as `macos/Headroom-CloudKit.ckdb` instead of living
  only in Apple's web console. It has to be deployed to Production before
  multi-Mac can work at all: released builds are pinned to that environment,
  and CloudKit creates record types automatically only in Development. See
  `docs/multi-mac.md`.

## 1.2.1 — 2026-07-30

### Fixed

- Multi-Mac over iCloud now works in released builds. Every release up to 1.2.0
  was notarized without the iCloud provisioning profile, so the published app
  carried no CloudKit entitlement and Settings reported iCloud as unavailable
  on every Mac that downloaded one. Nothing was red: the release was properly
  signed and notarized, and only a note in the build log said the feature was
  off. The workflow now embeds the profile, and refuses one whose team does not
  match the signing certificate. An app downloaded before this release does not
  gain iCloud, because entitlements are sealed into a signature.
- Settings no longer claims that signed releases can use iCloud. That was false
  for exactly the people reading it on a notarized release, and sent them to
  download another copy of what they already had. A local build and a release
  built without the profile now say different things.
- The iOS archive stopped minting a `Created via API` development certificate
  on every run, which walked the team toward its certificate cap and then
  failed the archive itself with `Choose a certificate to revoke`.
- iOS release builds no longer break on SDK-specific `CODE_SIGN_IDENTITY` keys
  written into the pbxproj unquoted.

## 1.2.0 — 2026-07-30

### Added

- Major Claude outages on status.claude.com light Attention — partial blips
  stay quiet.

## 1.1.9 — 2026-07-30

### Fixed

- Claude auth no longer borrows Claude Code's Keychain on every poll. Headroom
  imports the plan token once into `~/.headroom/oauth/` (one file per account),
  refreshes only that copy, and never writes back into Claude Code's item. A
  Keychain Deny stays denied until you refresh the source in Settings, instead
  of retrying every 20 seconds and re-prompting. Named Claude accounts each get
  their own Headroom file, same as before.


### Added

- Settings → General can open Headroom at login. macOS may still ask once in
  Login Items; the toggle says so and links there when approval is pending.

## 1.1.7 — 2026-07-30

### Changed

- Named accounts next to a brand mark show the user label (`Work`), not
  `Claude · Work`. The mark already names the tool; repeating it is how a row
  of Claude tabs all truncated to "Claude…". Full titles stay in Settings, the
  menu bar and other text-only surfaces.

## 1.1.6 — 2026-07-29

### Added

- Coding agents can ask you things through Headroom. When Codex wants to run a
  command or change a file, the approval becomes an item you can answer from
  the Mac or the phone rather than a terminal you are not sitting in front of.
  Each request is held until it is answered or expires, so a question does not
  disappear when the session behind it drops. Codex is the first provider, and
  the feed does not care which agent a request came from.

### Changed

- Other Macs sync over iCloud instead of a shared folder, so there is no
  directory to agree on: turn it on and the Macs find each other. Setting
  `icloud_dir` to a path still uses the folder transport.
- Settings is organised around what you are looking for rather than which part
  of the app happens to own it.
- The watch tile drops its headline at small sizes. Around 160 by 72 points the
  legend, the percent gutter and the weekday labels all stop being readable, so
  the chart takes the whole tile instead of competing with text.
- A full ring keeps a visible seam at 12 o'clock where its two caps meet,
  rather than closing into a solid circle you cannot read a value off.

### Fixed

- A weekly countdown that briefly sampled under the wrong Claude login no
  longer sticks for the rest of the week. The held reset re-anchors when the
  live reading points at an earlier instant, so one account stops showing
  another's "6d 19h".

## 1.1.5 — 2026-07-29

### Fixed

- The iPhone app reaches TestFlight again. Every release since 1.0.9 built it
  and then failed to sign it, so testers stayed on a build from 28 July while
  the Mac app went on to 1.1.4. Releases now sign the export with the team's
  distribution certificate and named App Store profiles, rather than asking the
  build machine to create credentials it has no way to create.

### Added

- `scripts/ship-ios.sh` sends a release to TestFlight from a Mac for when the
  workflow cannot. It refuses to run on a dirty tree or away from the release
  tag: the build number comes from the commit, and a build uploaded under the
  wrong one cannot be taken back.

## 1.1.4 — 2026-07-29

### Added

- Headroom is aware of your other Macs. Settings → Other Macs turns on sharing,
  and each Mac then publishes a small summary of itself to a folder in your
  iCloud Drive: what it is burning, how many local servers it has up, and
  whether it needs your attention. The popover lists the others with their own
  timestamps rather than merging them into one reading, because two Macs are
  allowed to disagree. Off until you turn it on.
- Enabled sources, pinned provider order, accent colours and the non-secret
  half of `config.json` follow you between Macs. Opening Headroom on a second
  Mac adopts the settings already in the folder instead of starting from
  defaults. Credentials and machine paths are never synced. See
  [docs/multi-mac.md](docs/multi-mac.md).
- A first-run Welcome window introduces the menu bar app, dashboard, quota
  rings, burndown charts, iPhone, Apple Watch and ESP32 companion. Settings can
  reopen it later, and About now carries the app version and product credits
  on both Mac and iPhone.
- Banked Codex reset credits now show their own expiry deadline on burndown
  charts, distinct from quota renewals and provider-granted resets.
- The ESP32 glance includes a compact burndown view, recent local Git activity
  and clearer host connection diagnostics.

### Changed

- The Mac quota dashboard adapts its tabs and card grid to the number of
  enabled providers instead of reserving space for providers that are hidden.
- Multi-Mac sharing can be enabled, disabled and inspected directly in
  Settings, including the current Mac, discovered peers and sync directory.

### Fixed

- The LaunchAgent now runs from `~/.headroom` rather than the read-only bundled
  host directory, so runtime state and relative writes have a writable home.

## 1.1.3 — 2026-07-29

### Fixed

- Named Claude accounts now read the Keychain credentials for their own
  profile instead of reusing the default account, so each account reports its
  own quota and stale state.

## 1.1.2 — 2026-07-29

### Fixed

- The macOS download is signed with Developer ID and notarized. Earlier
  releases shipped ad-hoc signed, so Gatekeeper refused to open them and
  reported that it could not verify the app. The signing certificate stored in
  CI held a private key with no certificate alongside it, which left the build
  job with no usable identity and sent it down its unsigned fallback path
  without failing.

## 1.1.1 — 2026-07-29

### Added

- Provider marks now identify every coding quota across the Mac, iPhone, and
  ESP32 dashboards, including named accounts under each provider.

## 1.1.0 — 2026-07-29

### Added

- Headroom now runs on Apple Watch with quota-ring and burndown
  complications. The iPhone forwards its existing snapshot over
  WatchConnectivity, so the watch does not need a second API or direct access
  to the Mac.
- Provider-granted resets now remain visible instead of making the burndown
  look as if it forgot the previous window. Charts show the forgiven curve and
  reset marker, the activity feed records the grant, and the ESP32 receives a
  compact version of the same history.
- The ESP32 has a generated cold-boot sequence plus an on-screen connection
  diagnosis that distinguishes Wi-Fi, host resolution, token, HTTP, and USB
  failures. The new flashing helper refuses to race another process for the
  serial port.
- Claude, Codex, and Cursor marks now identify their tabs in the Mac
  dashboard, including named accounts under each provider.

### Fixed

- **Claude quota could sit fifteen hours out of date and still read as live.**
  Claude Code keeps per-MCP-server OAuth in the same Keychain item as your plan
  token. Once that item held only `mcpOAuth`, the search for credentials ended
  there instead of going on to `~/.claude/.credentials.json`, so every fetch
  failed and no fresh login could bring it back. The search now passes over a
  store that has no plan token in it, and when there is none anywhere it tells
  you to run `claude login` rather than naming a missing JSON key.
- A source that has been failing for a day no longer reports as one poll old.
  Payloads carry the moment they were fetched; the poll clock only ever knew
  when we last *tried*, and a failing source is retried on the same schedule as
  a healthy one. This is what the menu bar's "N minutes stale" line reads, so
  it had been stuck at one minute for the whole outage. Snapshots written
  before the field get their age from the cache file's mtime, so the count is
  right on the first poll after upgrading rather than a fetch later.
- Stale quota no longer drives anything measured against the clock. The
  percentages still show — last-known beats blank — but the countdown, the
  pace, and the burndown chart drop out instead of being computed off a reading
  that has stopped moving. A frozen `resets_in_s` counted down was the most
  convincing wrong number on the card: right shape, right units, ticking a dead
  window to zero in front of you. One missed poll is still treated as a blip
  and changes nothing.
- Stale readings are no longer written to the quota sample log. Re-recording
  one reading laid down a flat line indistinguishable from a real idle stretch,
  and each sample walked the derived window forward, so a source that stopped
  answering last night still showed windows rolling on schedule today.

### Changed

- `providers[]` carries `stale`, `age_s`, and `stale_for_s` per source, so a
  client can tell last-known numbers from current ones without inferring it
  from an absent countdown.
- Activity rows now state their outcome and what needs attention in words.
  Colour remains supporting information rather than the only status signal.
- Quota rings use the sampled burndown pace when it is available, and visibly
  mark a provider whose last-known reading is no longer updating.
- Unconfigured Plausible and Supabase services stay out of the Mac and iPhone
  dashboards until they are enabled in Settings.
- App icons now use process cyan, magenta, and yellow rings so their three
  bands remain distinct at small catalog sizes.

### Fixed

- The app no longer reports its own staleness as the host's. It fingerprinted
  the host it bundles once per launch, on the premise that a running .app owns
  a read-only bundle — false every time a build lands on top of a running copy.
  The app then compared a dead fingerprint against a live host and offered an
  update that reinstalled the host already running, for ever. The fingerprint
  now recomputes when the files under `Resources/host` move.
- Skew has a direction. A host reporting a newer release line than the .app is
  no longer replaced with an older copy; the banner names the app as the half
  that needs updating and drops the button.
- Starting the host waits for the host it started. A 200 on :8737 was taken as
  success, which the process being replaced answers on its way out — and which
  a foreign host answers for ever, since ours stands down by design when the
  port is taken. Startup now waits for the fingerprint it installed, and says
  so when something else owns the port instead of reporting success.
- One install at a time. Launch, the poll loop, the setup card and the skew
  banner each ran their own bootout/bootstrap; whoever lost the race read
  `/usage` from a host mid-restart, which is how "Host is up" and "Could not
  connect to the server" ended up on screen together.
- The LaunchAgent asks for `KeepAlive/SuccessfulExit=false`. The host exits 0
  on purpose when another process owns the port, but an unconditional
  `KeepAlive` ignores exit status and respawned it every 5 seconds for ever,
  each respawn rescanning a week of logs.
- One failed call no longer counts as "no host". A refused server stop or a
  single flaky poll replaced the whole dashboard with the onboarding sheet;
  that now keys on whether `/health` answers.
- The setup card re-checks while it is open, instead of showing three lines
  captured at three different moments.

## 1.0.11 — 2026-07-29

### Added

- The widget now runs in macOS Notification Center, not just on the phone.
  Rings on the small size, combined burndown on the medium one, same as iOS.
- The Mac widget is current rather than a refresh interval behind. The app is
  the source of its own data, so it writes the shared cache after every
  successful poll of its host. The phone can only write after a background
  refresh, which iOS schedules when it feels like it.

### Changed

- One widget source, `widget/HeadroomWidget.swift`, builds for both platforms.
  What differs is the group id, which macOS prefixes with the team, and the
  Info.plist and entitlements under `widget/ios` and `widget/macos`.
- Quota presentation logic moved out of the iPhone target into
  `Shared/QuotaPresentation.swift` so both widgets and both apps read one
  implementation.
- The Mac app and its extension share an App Group. The app is not sandboxed
  and the extension is, so the group is the only thing between them.

### Fixed

- `build-app.sh` signs the extension separately from the app instead of with
  `--deep`. The two take different entitlements, and `--deep` stamped the
  app's onto the sandboxed extension, which then lost the group container.
  The build now also verifies both ends resolve to the same group, because a
  mismatch fails as a widget that loads and draws the placeholder for ever.

## 1.0.10 — 2026-07-29

### Fixed

- Building the iPhone app from a clean clone failed for everyone outside the
  maintainer's Apple team: `No profiles for 'com.centaur-labs.headroom' were
  found`. The documented command had no unsigned path and no
  `-allowProvisioningUpdates`, so automatic signing could never mint anything.
  There is now a simulator build that needs no Apple account, and the device
  build documents the two things a fork must change first.

### Changed

- The signing table in `CONTRIBUTING.md` no longer claims iOS profiles are
  "nothing to edit". `com.centaur-labs.*` belongs to one team and Apple will
  not issue it to another.
- CI-equivalent iOS simulator build added to the contributor build list.

## 1.0.9 — 2026-07-28

### Added

- The ESP32 reads its providers, their order, and their colours from the host
  instead of carrying its own copy.
- Per-provider colour override in Settings.
- Richer widget overview and shared ring polish across Mac and iPhone.

### Changed

- Burndown chart math and canvas furniture extracted into `Shared/` so the
  three clients draw from one implementation.
- App icon regenerated from the ring glyph.

### Fixed

- Firmware pace dots, and host accent colours that did not always land.

## 1.0.8 — 2026-07-28

### Added

- More than one account per provider. Each account meters separately and the
  pool ranks fold them together.

## 1.0.7 — 2026-07-28

### Added

- GitHub Actions watch list in Settings, spanning repos from more than one
  owner.
- Supabase security advisors, fetched separately from project health, with UI
  on both clients.
- Host Settings API backing the watch list and advisor activity.

### Fixed

- The Mac app degrades gracefully against a host with no `/github/watch`
  instead of showing an empty pane.
- The `/usage` filter contract no longer pins itself to one firmware
  signature.
- Firmware builds its JSON usage filter once, in PSRAM.
- iOS archives export with automatic signing.

## 1.0.6 — 2026-07-28

### Fixed

- Firmware projection dashes run along path length and open up enough to read
  at desk distance.

## 1.0.5 — 2026-07-28

### Added

- Shared palette, compact number format, and a 7-day burndown axis used by all
  three clients.

### Changed

- Host derives `Source` detail, summary, and blank states from pools.
- `urllib` plumbing shared through `http_util`.

### Fixed

- Burndown never renders in the alarm tint, which previously read as a warning
  when nothing was wrong.

## 1.0.4 — 2026-07-28

### Added

- Host pins source order and ships a top-3 focus that every surface honours.
- Drag-to-reorder in Mac Settings, week burndown, and the app icon.
- Focus rendering on iOS quota surfaces and an ASCII-safe firmware glance.

### Changed

- Signing uses `$HEADROOM_TEAM_ID` instead of a hardcoded team.
- The generated Xcode project is no longer tracked. `macos/project.yml` is the
  source of truth.
- Contributing guide, security policy, and backlog added for the public repo.

### Fixed

- The host token stays out of the launchd logs.

## 1.0.3 — 2026-07-28

### Fixed

- Release CI imports the full Developer ID identity so notarization completes.

## 1.0.2 — 2026-07-28

### Fixed

- First attempt at the Developer ID import above. Superseded by 1.0.3.

## 1.0.1 — 2026-07-28

### Added

- First public macOS zip.
- iOS releases publish through `asc` to the Internal TestFlight group.
- App Store listing copy, privacy policy, icon, and framed iPhone slides.

### Fixed

- iOS declares itself export-compliance exempt so TestFlight can assign builds.
- TestFlight export uses manual App Store profiles.

## 1.0.0 — 2026-07-28

First tagged release.

### Added

- Menu bar app with a welcome flow, bundled-host control, and enabled-only
  providers.
- Registry-driven quota providers in the host, local detection, and `/setup`.
- `HeadroomMobile` companion app reading the same shared usage document.
- ESP32 firmware with a Cursor Total+API burndown overlay, stamped with a
  local build counter and commit hash.
- Shared models across Mac and iPhone under the Headroom name.
- Host `VERSION` fingerprint so the app can tell a stale LaunchAgent from a
  current one.
- Apple commit-count versions, notarization, and TestFlight CI.

### Changed

- Burndown and quota rings use brand-tint-only styling.
- GitHub Actions failures age out of Attention and the activity feed.

### Fixed

- iOS keeps the last `/usage` on disk when the Mac is unreachable, and forces a
  source sync when recovering from a stale archive.
- macOS forces a source sync after wake and shows a reconnecting status.
- Flat burndown projections are skipped rather than painting a misleading level
  bar.
