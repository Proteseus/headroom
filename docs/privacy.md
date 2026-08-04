# Privacy Policy — Headroom

**Last updated:** 31 July 2026

Headroom is a local-first tool for viewing AI coding quotas and related
development status. This policy covers the **Headroom iOS / iPadOS app**
(`com.centaur-labs.headroom`) and how it relates to the optional Mac host.

## Summary

- Headroom does **not** operate a cloud account for itself.
- The iOS app does **not** sell, rent, or share personal data with advertisers.
- Provider credentials (Claude, Codex, Cursor, GitHub, Supabase, Plausible, PostHog, …)
  remain on your Mac. The phone never stores those secrets.
- The phone stores only what it needs to talk to *your* Mac: endpoint URL and a
  **mobile pairing token**, plus a local cache of the last usage snapshot for
  offline display.

## What the iOS app does

1. Discovers Headroom Mac hosts on your local network (Bonjour) or connects to a
   URL you enter (LAN / Tailscale).
2. Requests the usage document from that host over HTTP(S) using your mobile
   token and the permissions you configured on the Mac (`read`, `refresh`,
   `sources`, `servers`, `agents`).
3. Optionally sends local notifications when the host reports attention-level
   warnings.
4. Optionally uses Face ID / device authentication before asking the Mac to
   stop a local development server, or to answer or interrupt a coding agent.

### Answering coding agents

With the `agents` permission granted on the Mac, the app can show what a coding
agent (Claude Code, Codex) is asking permission to do, and send back your
answer. This means the phone displays **the agent's actual request** — the
command it wants to run, the file it wants to write, the text it wants to
change — because an approval you cannot read is not an approval.

- Those request details travel from your Mac to your phone over your own
  network, and are cached on the phone like any other part of the snapshot.
- A question the agent marks as secret is **never** sent to the phone and never
  recorded on the Mac.
- The permission is off until you turn it on in Mac Settings, and you can
  revoke it there at any time.

## Mac anonymous diagnostics

The **Mac app** can send one aggregate diagnostics batch per week when
**Share anonymous product diagnostics** is left on (Settings → Telemetry).
That batch is described in [`docs/telemetry.md`](telemetry.md): no prompts,
paths, tokens, or stable install ids. A week-scoped HMAC dedupe key prevents
the same Mac from inflating a week’s count; the secret that produces it never
leaves the Mac. Country is derived at the edge from Cloudflare geo (ISO code
only); the IP is not stored. The iOS app does not send this. Turning the
setting off deletes any pending local batch.

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
| Last `/attention/events` payload | On-device archive / App Group |
| Provider API credentials | Mac Keychain / local CLIs only |
| Host auth token (ESP32 / LAN) | Mac `~/.headroom/token` |
| Multi-Mac settings + machine summary | Off by default. When you turn on `icloud_sync`, your own iCloud Drive |
| Coding-agent request history | Mac `~/.headroom/attention.sqlite3` |

**About the agent history.** When a coding agent asks Headroom for permission,
the request is recorded on your Mac so the phone can show it, so answering it
twice cannot happen by accident, and so you can see what you approved. That
record includes the fields of the request itself — commands, file paths, and
excerpts of code — each capped in length. The provider's raw request object is
not stored, and secrets are never recorded at all.

This file lives only on your Mac, is never synced, and is never uploaded.
Answered requests are **deleted automatically after 30 days**, counted from
when you answered. A request still waiting on you is kept regardless of age,
because something is still blocked on the answer.

To clear it by hand, delete `~/.headroom/attention.sqlite3` with the host
stopped. That costs you nothing but the record.

Multi-Mac sync writes one small file per Mac into a folder in *your* iCloud
Drive so a second Mac can pick up your settings and show what the first one is
doing. It is off until you turn it on in Settings → Other Macs, it never
carries credentials or file paths, and there is still no Headroom account or
Headroom server involved. See [multi-mac.md](multi-mac.md).

Deleting the iOS app removes its Keychain items and local cache for that
install. Uninstalling the Mac host / purging `~/.headroom` removes host-side
state.

## Network

The iOS app communicates with the Mac host you choose. That host may call
third-party APIs (Anthropic, OpenAI/Codex, Cursor, GitHub, Vercel, Supabase,
Plausible, PostHog, …) using credentials you already configured on the Mac. Those
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
