# Headroom for the menu bar

Native macOS 14+ companion to the ESP32 display. Same
`http://127.0.0.1:8737/usage` feed.

- Status item: three thin remaining-quota meters (Claude, Codex, Cursor) plus an
  amber/red attention pip
- Overview: quota rings, daily burn, attention + spend
- Provider tabs + activity / Supabase / local servers
- Settings: endpoint, source toggles, tokens

## Build

```sh
cd macos
xcodegen generate   # after project.yml changes
xcodebuild \
  -project HeadroomBar.xcodeproj \
  -scheme HeadroomBar \
  -configuration Debug \
  -derivedDataPath .build \
  build
open ".build/Build/Products/Debug/HeadroomBar.app"
```

No Dock icon. Start the host first:

```sh
python3 ../host/headroom_server.py
```

## README screenshots

From the repo root (exports Overview against `docs/demo_usage.json`):

```sh
./scripts/generate_screenshots.sh
```

Or only the app export:

```sh
HeadroomBar.app/Contents/MacOS/HeadroomBar \
  --export-screenshots ../docs/screenshots \
  --fixture ../docs/demo_usage.json
```
