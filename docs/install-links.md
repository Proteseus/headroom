# Install links

Canonical download URLs for the README and GitHub Release notes.
Edit this file when a link changes; leave a line blank until it exists.

| Surface | URL / id |
|---|---|
| **macOS Releases** | https://github.com/michellzappa/headroom/releases |
| **iOS TestFlight** | https://testflight.apple.com/join/PsQY3YET |
| **ASC app id** | `6795549853` |
| **TestFlight group** | `Public` (`a572df15-eaff-47f2-96e4-0cd2e17af70a`) · Internal `3dfef92a-a2c3-4ff8-954c-55b4e03f21c7` |

## How to fill TestFlight

1. App Store Connect → **Headroom** (`com.centaur-labs.headroom`, id `6795549853`) → TestFlight.
2. Create a **Public Link** group (or enable Public Testing) and copy the join URL
   (`https://testflight.apple.com/join/…`).
3. Paste that URL into the **iOS TestFlight** cell above (no backticks).
4. Commit — the next `v*` tag release embeds it in the GitHub Release body.

External builds need Beta App Review before strangers can install via the public link.
Internal testers on the Apple team can use the Internal group without that review.
