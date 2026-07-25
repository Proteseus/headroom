#!/usr/bin/env bash
# Generate README screenshots from docs/demo_usage.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/docs/screenshots"
FIXTURE="$ROOT/docs/demo_usage.json"
VENV="$ROOT/.venv-shots"
APP_BUILD="$ROOT/macos/.build/Build/Products/Debug/HeadroomBar.app"

mkdir -p "$OUT"

if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q pillow
fi

echo "→ ESP32 glance preview"
"$VENV/bin/python" "$ROOT/scripts/render_esp32_preview.py" \
  --input "$FIXTURE" \
  --out "$OUT/esp32-glance.png"

echo "→ build HeadroomBar (Debug)"
cd "$ROOT/macos"
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate >/dev/null
fi
xcodebuild \
  -project HeadroomBar.xcodeproj \
  -scheme HeadroomBar \
  -configuration Debug \
  -derivedDataPath .build \
  build \
  >/tmp/headroom-shot-build.log

echo "→ export macOS popover + icon"
# Quit any running copy so we can launch the export binary cleanly.
pkill -x HeadroomBar 2>/dev/null || true
sleep 0.4
"$APP_BUILD/Contents/MacOS/HeadroomBar" \
  --export-screenshots "$OUT" \
  --fixture "$FIXTURE"

echo "→ compose menubar hero"
"$VENV/bin/python" "$ROOT/scripts/compose_menubar_preview.py" \
  --fixture "$FIXTURE" \
  --popover "$OUT/macos-popover.png" \
  --icon-out "$OUT/macos-menubar-icon.png" \
  --out "$OUT/macos-menubar.png"

echo "done → $OUT"
ls -la "$OUT"
