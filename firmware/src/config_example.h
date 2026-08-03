// Copy this file to config.h and fill in your values. config.h is gitignored
// so your Wi-Fi passwords never land in the repo.
#pragma once

// ---- Wi-Fi networks (tries whichever is in range) ----
// Add every network the tracker might travel to: home, your phone hotspot,
// office, etc. On the road: either tether both this board AND your Mac to a
// phone hotspot, or plug the board into the Mac over USB (host speaks HR over
// CDC). Hotel Wi-Fi usually blocks the Wi-Fi path (captive portals a headless
// board can't click through, plus client isolation).
static const struct { const char *ssid; const char *pass; } WIFI_NETWORKS[] = {
    {"home-ssid", "home-password"},
    {"phone-hotspot", "hotspot-password"},
    // add more {"ssid", "password"}, lines as needed
};

// ---- Host server ----
// Resolved by name via Bonjour/mDNS, so the Mac's changing IP doesn't matter —
// as long as both are on the same network. HOST_NAME has no ".local" suffix.
#define HOST_NAME "your-mac-hostname"   // `scutil --get LocalHostName` on the Mac
#define HOST_PORT 8737

// Fallback used only if mDNS can't resolve HOST_NAME (e.g. a network that
// blocks mDNS). Set to the Mac's IP on that network, or leave as-is.
#define HOST_FALLBACK_IP "192.168.1.50"

// Host token for LAN access (ESP32 / generic clients). /usage carries repo
// names, commit subjects, local server paths and spend, so the host requires
// this from anything that isn't loopback. Stored at ~/.headroom/token after
// first host start — not the iPhone mobile token (~/.headroom/mobile-token).
// Leave empty only if you set "require_auth": false in ~/.headroom/config.json.
// Not needed for the USB path: the cable already implies physical access.
#define HOST_TOKEN ""

// Seconds between polls. The server refreshes its own data every 15s.
#define POLL_INTERVAL_S 60

// Over-the-air updates. With this on, `pio run -t upload --upload-port
// headroom.local` reflashes without the cable. Set a password you don't mind
// living in this file; anyone on the network who has it can flash the board.
#define OTA_HOSTNAME "headroom"
#define OTA_PASSWORD "change-me"

// ---- Auto brightness (AMOLED) ----
// Local solar times from lat/lon + a fixed bedtime. Defaults are Amsterdam.
// Schedule (local clock):
//   day      → 100% from (sunrise − lead) until evening dim
//   evening  → ~30% from (sunset + lag) until bedtime
//   night    → ~10% from bedtime until (sunrise − lead)
// Winter: sunset is early, so evening can last hours — intentional.
// Summer: if sunset+lag falls after bedtime, evening is skipped and the
// panel goes day → night at bedtime (no haywire late-dusk plateau).
#define BRIGHTNESS_AUTO 1
#define LATITUDE  52.3676
#define LONGITUDE 4.9041
// POSIX TZ for SNTP + localtime. Europe/Amsterdam:
#define TIMEZONE_POSIX "CET-1CEST,M3.5.0/2,M10.5.0/3"
#define BRIGHTNESS_DAY          200   // panel units 0–255; boot used this
#define BRIGHTNESS_EVENING_PCT   30   // percent of DAY
#define BRIGHTNESS_NIGHT_PCT     10
#define BRIGHTNESS_BEDTIME_MIN  (22 * 60)  // 22:00 local
#define BRIGHTNESS_SUNSET_LAG_MIN   30
#define BRIGHTNESS_SUNRISE_LEAD_MIN 30
