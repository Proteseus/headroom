# Headroom for the menu bar

Native macOS 14+ companion. The Release `.app` **bundles the Python host** —
first launch’s Welcome sheet starts it automatically and installs a login item.

- Status item: thin remaining-quota meters for **enabled** providers + attention pip
- Overview: quota rings, daily burn, attention + spend
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
