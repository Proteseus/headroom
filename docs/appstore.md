# App Store Connect — Headroom

Canonical listing copy for the **iOS** companion
(`com.centaur-labs.headroom`, ASC id `6795549853`).
Push with Tiny’s metadata script or paste into ASC / `asc metadata`.

macOS ships via GitHub Releases (Developer ID), not the Mac App Store — yet.

## App Information

- **App Name**: Headroom
- **Subtitle** (30 chars max): Local-first coding quotas

> The name field read `Headroom (Max your Quotas)`. Two problems: it stuffs
> keywords into the one field Apple asks you not to, and "Max your Quotas"
> reads as *maximise your usage* — the opposite of what the app is for, which
> is not running out. The keyword field already carries those words.
> **Renaming a live listing needs a review cycle**, so this is the copy to
> submit with next time, not something to push on its own.
- **Bundle ID**: com.centaur-labs.headroom
- **SKU**: com.centaur-labs.headroom
- **Primary Language**: English (U.S.)
- **Category**: Developer Tools
- **Secondary Category**: Productivity
- **Content Rights**: Does not contain third-party content
- **Age Rating**: 4+

## Listing copy

Not pinned to a version. This file was headed "Version 1.0.3" and sat there
through 1.2.7, because the description and keywords do not change per release
and nobody was going to renumber a heading that meant nothing. **What's New is
the only per-release field, and its source is `CHANGELOG.md`** — copy the
section for the version being submitted rather than maintaining a second one
here that drifts.

### Description (4000 chars max)

Headroom keeps your AI coding quotas and ship status in one glance — on your
iPhone, beside the Mac menu bar, and (optionally) on a desk display.

When you’re deep in Claude, Codex, or Cursor, you shouldn’t have to dig through
billing pages, `gh`, and dashboards to answer: Am I about to hit a limit? Did
CI go red? Is prod healthy?

Headroom’s companion app on iPhone and iPad reads a local feed from a small
host on your Mac. No Headroom cloud account. Provider credentials stay in the
Mac Keychain. The phone only gets what you grant: read, refresh, source
toggles, and stopping local servers.

Features:
- Coding quota rings for Claude, Codex, and Cursor — remaining %, pace, resets
- Burndown and daily burn across providers
- Activity feed: deploys, commits, and GitHub Actions
- Services: Supabase health, Plausible traffic, local listening ports
- Attention summary with optional notifications when something needs you
- Home Screen widgets backed by an on-device cache
- Bonjour discovery of nearby Macs (Tailscale / LAN fallback)
- Face ID before stopping a development server on your Mac
- Pull-to-refresh that can force the Mac host to re-poll sources

Pair once: keep Headroom running on the Mac, allow Local Network on the phone,
pick your Mac under Nearby Macs, paste the mobile token from Mac Settings →
iPhone pairing.

Hardware is optional. The Waveshare ESP32 desk display and the macOS menu bar
app share the same local host — this iOS app is the pocket companion.

### Keywords (100 chars max, comma-separated)

quotas,claude,codex,cursor,developer,ci,vercel,supabase,menubar,local,burn

### What's New

Take the `CHANGELOG.md` section for the version being submitted.

### Promotional Text (170 chars max, can be updated without review)

Know what's left before you hit the wall. Claude, Codex, and Cursor quotas on
your phone — local-first, no Headroom cloud account.

### Support URL

https://github.com/michellzappa/headroom/issues

### Marketing URL (optional)

https://github.com/michellzappa/headroom

### Privacy Policy URL (required)

https://github.com/michellzappa/headroom/blob/main/docs/privacy.md

## Privacy Details

- **Data Collection**: None by Headroom itself — the iOS app talks only to your
  Mac host over the local network / Tailscale
- **Tracking**: No
- **Data Linked to You**: None
- **Data Not Linked to You**: None
- **Third-party SDKs**: None (no analytics, ads, or crash reporters)
- **Local Network**: Used to discover and reach the Headroom host on your Mac
- **Face ID**: Optional, only before stopping a local server you choose
- **Credentials**: Provider tokens (Claude, GitHub, Supabase, …) stay on the Mac;
  the phone uses a separate mobile pairing token

## Screenshots (required)

Apple sizes (portrait):

| Device class | Size (px) |
|---|---|
| iPhone 6.7" | 1290 × 2796 |
| iPhone 6.5" | 1284 × 2778 |
| iPad 12.9" (if shipping iPad) | 2048 × 2732 |

Minimum: **3** iPhone shots. Aim for **5–6** that sell one idea each
(not a UI tour). Working captures live under `docs/screenshots/` — regenerate
framed App Store slides later.

Recommended set:

1. **Overview rings** — “Your quotas, one glance”
2. **Provider detail / burndown** — “Pace before you hit the wall”
3. **Activity** — “CI and deploys without another tab”
4. **Services** — “Supabase, Plausible, local ports”
5. **Pairing / Nearby Macs** — “Local-first. Your Mac, your tokens.”
6. **Widget** — “On the Home Screen, too”

Source fixtures today:

- Device captures: `docs/screenshots/ios-{overview,quotas,activity,services}.png`
- Framed 6.7″ slides (1290×2796): `docs/appstore/screenshots/01-*.png` …
- Regenerate: `./scripts/generate_screenshots.sh`

## App Icon

- 1024×1024 PNG, no transparency, no rounded corners
- Ready to upload: [`docs/appstore/icon-1024.png`](appstore/icon-1024.png)
- Source asset: `ios/HeadroomMobile/Assets.xcassets/AppIcon.appiconset/HeadroomIcon.png`

## Pricing

- **Price**: Free
- **Availability**: All territories
- **IAP**: None

## Notes for Review

Headroom for iPhone is a companion to a local Mac host included with the
open-source Headroom project (https://github.com/michellzappa/headroom).

To review:

1. On a Mac, install Headroom from GitHub Releases (or build from source) and
   complete the Welcome sheet so the host is running on port 8737.
2. On the review device, allow Local Network access when prompted.
3. Open the app → Nearby Macs should list the review Mac (same Wi‑Fi). Tap it.
4. On the Mac: Settings → iPhone pairing → Copy mobile token → paste on the
   phone → Connect.

If Bonjour fails on the review network, enter:

```text
http://<mac-lan-ip>:8737/usage
```

and the mobile token from `~/.headroom/mobile-token`.

The app does not require an Apple ID login, Headroom account, or third-party
API keys on the phone. Quota data appears only after the Mac host can read
local Claude / Codex / Cursor sign-in state. Demo fixture mode is not required
for a basic pairing + empty/error UI review; for populated quotas, sign into at
least one coding tool on the Mac before pairing.

Export compliance: the app only uses standard HTTPS / local HTTP for the host
feed (`ITSAppUsesNonExemptEncryption` = false).

## Checklist before submit

- [ ] Name + subtitle saved in ASC (EN-US)
- [ ] Description / keywords / promo / what’s new pasted or pushed
- [ ] Privacy URL reachable
- [ ] Support URL reachable
- [ ] 1024 icon uploaded
- [ ] ≥3 iPhone screenshots uploaded (framed)
- [ ] Build selected on the iOS version (TestFlight build 47+ )
- [ ] Age rating / content rights completed
- [ ] Review notes pasted
- [ ] Internal TestFlight smoke on a physical phone
