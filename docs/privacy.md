# Privacy Policy — Headroom

**Last updated:** 28 July 2026

Headroom is a local-first tool for viewing AI coding quotas and related
development status. This policy covers the **Headroom iOS / iPadOS app**
(`com.centaur-labs.headroom`) and how it relates to the optional Mac host.

## Summary

- Headroom does **not** operate a cloud account for itself.
- The iOS app does **not** sell, rent, or share personal data with advertisers.
- Provider credentials (Claude, Codex, Cursor, GitHub, Supabase, Plausible, …)
  remain on your Mac. The phone never stores those secrets.
- The phone stores only what it needs to talk to *your* Mac: endpoint URL and a
  **mobile pairing token**, plus a local cache of the last usage snapshot for
  offline display.

## What the iOS app does

1. Discovers Headroom Mac hosts on your local network (Bonjour) or connects to a
   URL you enter (LAN / Tailscale).
2. Requests the usage document from that host over HTTP(S) using your mobile
   token and the permissions you configured on the Mac (`read`, `refresh`,
   `sources`, `servers`).
3. Optionally sends local notifications when the host reports attention-level
   warnings.
4. Optionally uses Face ID / device authentication before asking the Mac to
   stop a local development server.

## Data we do not collect

Headroom (the product) does not run analytics SDKs, advertising SDKs, or
third-party crash reporters in the iOS app. We do not build advertising
profiles. We do not sell data.

## Data on your devices

| Data | Where it lives |
|---|---|
| Mobile pairing token | iOS Keychain |
| Host endpoint | iOS app preferences |
| Last `/usage` snapshot | On-device archive / App Group (widgets) |
| Provider API credentials | Mac Keychain / local CLIs only |
| Host auth token (ESP32 / LAN) | Mac `~/.headroom/token` |

Deleting the iOS app removes its Keychain items and local cache for that
install. Uninstalling the Mac host / purging `~/.headroom` removes host-side
state.

## Network

The iOS app communicates with the Mac host you choose. That host may call
third-party APIs (Anthropic, OpenAI/Codex, Cursor, GitHub, Vercel, Supabase,
Plausible, …) using credentials you already configured on the Mac. Those
requests are between your Mac and those providers under *their* policies —
not uploaded to a Headroom server.

## Children’s privacy

Headroom is not directed at children under 13.

## Contact

Questions about this policy: open an issue at
https://github.com/michellzappa/headroom/issues

## Changes

We may update this page when the product changes. The “Last updated” date at
the top will change when we do.
