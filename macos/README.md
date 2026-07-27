# Headroom for the menu bar

Native macOS 14+ companion. The Release `.app` **bundles the Python host** —
first launch can install it as a login item from the Welcome sheet.

- Status item: thin remaining-quota meters for **enabled** providers + attention pip
- Overview: quota rings, daily burn, attention + spend
- Welcome / setup sheet when the host is down or on first open
- Settings: endpoint, source toggles, tokens

## Easiest path

Download `HeadroomBar-macos.zip` from GitHub Releases, open the app, tap
**Start host & keep at login**.

Or from a clone:

```sh
./scripts/build-app.sh
open dist/HeadroomBar.app
```

## Debug build

```sh
cd macos
../scripts/sync-embedded-host.sh   # embeds ../host into the app bundle
xcodegen generate
xcodebuild \
  -project HeadroomBar.xcodeproj \
  -scheme HeadroomBar \
  -configuration Debug \
  -derivedDataPath .build \
  build
open ".build/Build/Products/Debug/HeadroomBar.app"
```

Full walkthrough: [../README.md](../README.md#quick-start-from-scratch).

## README screenshots

```sh
./scripts/generate_screenshots.sh
```
