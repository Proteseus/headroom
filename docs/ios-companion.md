# Headroom for iPhone

The iOS companion is a second application target in `macos/Headroom.xcodeproj`.
It reads the same registry-driven `/usage` document as the Mac menu bar app and
ESP32 display. No cloud service or second database is involved.

## Install

1. Prefer the public [TestFlight link](install-links.md) when published.
2. Otherwise build from source (below) or wait for an internal TestFlight invite.

## Pair

1. Mac host must be running (menu bar **Welcome** / LaunchAgent).
2. On iPhone: allow **Local Network**, open Headroom, pick your Mac under
   **Nearby Macs** (or paste a Tailscale / LAN URL).
3. On Mac: **Settings → iPhone pairing → Copy mobile token**.
4. Paste that **mobile token** on the phone → **Connect**.

Do **not** paste the **host token** (`~/.headroom/token`) — that is for the
ESP32 / generic LAN clients. The phone always uses
`~/.headroom/mobile-token`.

## Features

- Automatic discovery of nearby Headroom Macs over Bonjour.
- One-tap endpoint selection and the **mobile token** from Mac Settings →
  iPhone pairing. A `.local` hostname, LAN IP, or Tailscale MagicDNS name
  remains available as a fallback.
- Token stored in the iOS Keychain.
- Overview, provider detail, pace/reset data, burndown, and daily burn.
- Activity feed (deploys, commits, GitHub Actions) with deep links.
- Services: Supabase project health, Plausible traffic, and local servers.
- Source toggles, split into **AI coding tools** and **Dev tools** the same way
  Mac Settings splits them, plus Face ID-protected local server stops.
  Credentials remain in the Mac Keychain.
- Attention summary and local notifications.
- Small and medium Home Screen widgets backed by an App Group cache.
- Best-effort iOS background refresh.
- Pull-to-refresh, including the existing LAN-safe `POST /sync/refresh`.
- iPhone and iPad layouts from one target.

Every mobile operation requires the **mobile token**, a private/Tailscale client
address, the `X-Headroom-Client: ios` header, and its matching Mac-owned
permission: `read`, `refresh`, `sources`, or `servers`. Change the four grants
under Mac Settings → iPhone pairing. Provider credentials and permission
changes remain Mac-only.

## Build

Versions match macOS (`host/VERSION` + git commit count). For a Release IPA /
TestFlight upload see [releasing.md](releasing.md).

```bash
./scripts/build-ios.sh          # → dist/Headroom-iOS.ipa
# or debug from Xcode:
cd macos
xcodegen generate
xcodebuild -project Headroom.xcodeproj -scheme HeadroomMobile \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -configuration Debug build
```

For a physical phone, select `HeadroomMobile`, choose your Development Team,
enable the `group.com.centaur-labs.headroom` App Group for the app and widget identifiers,
and run on a device on the same network as the Mac. On first use, allow local
network access.

Normally the Mac appears automatically under **Nearby Macs**. For Tailscale or
manual fallback, use a connection such as:

```text
http://your-mac.local:8737/usage
```

Copy the **mobile token** from the Mac (Settings → **Copy mobile token**), or:

```bash
cat ~/.headroom/mobile-token
```

The iOS and macOS apps compile from the same `Shared/HeadroomModels.swift`
contract. They remain two platform artifacts in the same Xcode project/release;
an iOS app cannot be embedded inside a macOS `.app`.
