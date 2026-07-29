# Headroom for the menu bar

Native macOS 14+ companion. The Release `.app` **bundles the Python host** —
first launch’s Welcome sheet starts it automatically and installs a login item.

- Status item: thin remaining-quota meters for **enabled** providers + attention pip
- Overview: quota rings, daily burn, attention + spend
- Notification Center widget: the same extension the iPhone runs, rings on the
  small size and the combined burndown on the medium one
- Welcome / setup sheet when the host is down or on first open, asking about
  **AI coding tools** and **Dev tools** separately
- Settings: endpoint, the two source lists, host/mobile tokens, dev-tool keys

## Easiest path

Download `Headroom-macOS.zip` from GitHub Releases, open the app, confirm
providers on Welcome. Notarized builds open without Gatekeeper workarounds —
see [docs/releasing.md](../docs/releasing.md).

Or from a clone:

```sh
./scripts/build-app.sh
open dist/Headroom.app
```

Version is `host/VERSION` + git commit count (`./scripts/version-env.sh`).

**The widget needs a team on the signature.** App and extension share their
cache through an app group, and on macOS a group id carries the team id — so an
ad-hoc build, which is what `build-app.sh` produces without `--notarize`, is
denied the container and the widget draws its placeholder for ever. Run from
Xcode with your own team (automatic signing) or build `--release --notarize` to
see real numbers in Notification Center.

## Debug build

```sh
cd macos
../scripts/sync-embedded-host.sh   # embeds ../host into the app bundle
xcodegen generate
xcodebuild \
  -project Headroom.xcodeproj \
  -scheme Headroom \
  -configuration Debug \
  -derivedDataPath .build \
  build
open ".build/Build/Products/Debug/Headroom.app"
```

Full walkthrough: [../README.md](../README.md#quick-start).

## README screenshots

Regenerate ESP32 / macOS / iOS assets from `docs/demo_usage.json`:

```sh
./scripts/generate_screenshots.sh
```
