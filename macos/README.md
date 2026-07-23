# Headroom for the menu bar

A native macOS 14+ companion to the headroom ESP32 display. It reads the
same `http://127.0.0.1:8737/usage` backend and adds:

- CodexBar-matched 18pt menu-bar meters: 6pt primary and 4pt secondary;
- Claude, Codex, and Cursor switching with provider-specific limits;
- an Overview with ESP32-style quota rings for all three providers;
- CodexBar-style 6pt bars, pace stripes, typography, and reset rows;
- glanceable Vercel deployment, local server, git commit, and daily cost stats.

## Build

```sh
cd macos
xcodegen generate
xcodebuild \
  -project HeadroomBar.xcodeproj \
  -scheme HeadroomBar \
  -configuration Debug \
  -derivedDataPath .build \
  build
open ".build/Build/Products/Debug/HeadroomBar.app"
```

The app has no Dock icon. It expects the host daemon to already be running:

```sh
python3 ../host/headroom_server.py
```

The backend URL defaults to localhost. It can be changed from the app's
Settings scene while developing.
