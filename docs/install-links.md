# Install links

Canonical download URLs for the README and GitHub Release notes.
Edit this file when a link changes; leave a line blank until it exists.

| Surface | URL |
|---|---|
| **macOS Releases** | https://github.com/michellzappa/headroom/releases |
| **iOS TestFlight** | |

## How to fill TestFlight

1. App Store Connect → **Headroom** (`com.centaur-labs.headroom`) → TestFlight.
2. Create a **Public Link** group (or enable Public Testing) and copy the join URL
   (`https://testflight.apple.com/join/…`).
3. Paste that URL into the **iOS TestFlight** cell above (no backticks).
4. Commit — the next `v*` tag release embeds it in the GitHub Release body.

Until the cell is filled, README and release notes tell people to build the iOS
app from source ([ios-companion.md](ios-companion.md)).
