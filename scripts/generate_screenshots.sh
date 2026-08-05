#!/usr/bin/env bash
# Generate README screenshots from docs/demo_usage.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/docs/screenshots"
FIXTURE="$ROOT/docs/demo_usage.json"
VENV="$ROOT/.venv-shots"
APP_BUILD="$ROOT/macos/.build/Build/Products/Debug/Headroom.app"
IOS_DERIVED="$ROOT/macos/.build-ios-shots"
IOS_SIM_NAME="${HEADROOM_IOS_SIM:-iPhone 17}"

# HeadroomMobile embeds the watch app; the default Xcode reports a watchOS SDK
# but resolves destinations to "watchOS 26.5 is not installed". Prefer beta.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

mkdir -p "$OUT"

if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q pillow
fi

# Contract fixture keeps linear week curves + collapsed projections. Marketing
# shots need the staged stories shape_demo_usage_burndown writes — same ones
# --demo-burndown applies on the device projection.
SHAPED="$OUT/.demo_usage.shaped.json"
echo "→ shape demo burndown for screenshots"
"$VENV/bin/python" "$ROOT/scripts/render_esp32_preview.py" \
  --input "$FIXTURE" \
  --write-shaped-fixture "$SHAPED"
FIXTURE="$SHAPED"

echo "→ ESP32 glance preview"
"$VENV/bin/python" "$ROOT/scripts/render_esp32_preview.py" \
  --input "$FIXTURE" \
  --demo-burndown \
  --out "$OUT/esp32-glance.png"

echo "→ build Headroom (Debug)"
"$ROOT/scripts/gen-project.sh" >/dev/null
cd "$ROOT/macos"
xcodebuild \
  -project Headroom.xcodeproj \
  -scheme Headroom \
  -configuration Debug \
  -derivedDataPath .build \
  build \
  >/tmp/headroom-shot-build.log

echo "→ export macOS popover + icon"
# Quit any running copy so we can launch the export binary cleanly.
pkill -x Headroom 2>/dev/null || true
sleep 0.4
"$APP_BUILD/Contents/MacOS/Headroom" \
  --export-screenshots "$OUT" \
  --fixture "$FIXTURE"

echo "→ compose menubar hero"
"$VENV/bin/python" "$ROOT/scripts/compose_menubar_preview.py" \
  --fixture "$FIXTURE" \
  --popover "$OUT/macos-popover.png" \
  --icon-out "$OUT/macos-menubar-icon.png" \
  --out "$OUT/macos-menubar.png"

echo "→ pick iOS Simulator ($IOS_SIM_NAME)"
# Prefer an exact name match on the newest available runtime. Falling back to
# any iPhone avoids xcodebuild's OS=latest mismatch when a model only exists
# on an older simulator runtime.
UDID="$(
  IOS_SIM_NAME="$IOS_SIM_NAME" "$VENV/bin/python" - <<'PY'
import json, os, subprocess, sys
want = os.environ["IOS_SIM_NAME"]
data = json.loads(subprocess.check_output(
    ["xcrun", "simctl", "list", "devices", "available", "-j"], text=True))
preferred, fallback = [], []
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for d in devices:
        if not d.get("isAvailable", True):
            continue
        entry = (runtime, d["name"], d["udid"])
        if d["name"] == want:
            preferred.append(entry)
        elif d["name"].startswith("iPhone"):
            fallback.append(entry)
pool = preferred or fallback
if not pool:
    raise SystemExit(f"no iPhone simulator available (wanted {want!r})")
pool.sort(key=lambda x: x[0], reverse=True)
print(pool[0][2])
PY
)"
SIM_DESC="$(xcrun simctl list devices | grep "$UDID" | head -1 | sed 's/^ *//')"
echo "  using $SIM_DESC"

echo "→ build HeadroomMobile (Simulator)"
xcodebuild \
  -project Headroom.xcodeproj \
  -scheme HeadroomMobile \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$IOS_DERIVED" \
  build \
  >/tmp/headroom-ios-shot-build.log

IOS_APP="$(find "$IOS_DERIVED" -type d -name 'HeadroomMobile.app' | head -1)"
[[ -n "$IOS_APP" && -d "$IOS_APP" ]] || {
  echo "error: HeadroomMobile.app not found under $IOS_DERIVED" >&2
  exit 1
}

echo "→ export iOS tabs (overview / attention / activity)"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl uninstall "$UDID" com.centaur-labs.headroom 2>/dev/null || true
xcrun simctl install "$UDID" "$IOS_APP"
rm -f "$OUT"/.ios-shot-ready* "$OUT"/ios-*.png
xcrun simctl launch "$UDID" com.centaur-labs.headroom \
  --export-screenshots "$OUT" \
  --fixture "$FIXTURE" >/dev/null

for tab in overview attention activity; do
  marker="$OUT/.ios-shot-ready-$tab"
  for _ in $(seq 1 50); do
    [[ -f "$marker" ]] && break
    sleep 0.2
  done
  if [[ ! -f "$marker" ]]; then
    echo "error: iOS export never signaled ready for $tab" >&2
    xcrun simctl terminate "$UDID" com.centaur-labs.headroom 2>/dev/null || true
    exit 1
  fi
  sleep 0.35
  xcrun simctl io "$UDID" screenshot "$OUT/ios-$tab.png"
  rm -f "$marker"
  echo "  wrote $OUT/ios-$tab.png"
done

xcrun simctl terminate "$UDID" com.centaur-labs.headroom 2>/dev/null || true
rm -f "$OUT"/.ios-shot-ready*
echo "wrote iOS tab screenshots"

echo "→ frame App Store iPhone slides (6.7\")"
"$VENV/bin/python" "$ROOT/scripts/frame_appstore_screenshots.py" \
  --shots-dir "$OUT" \
  --out-dir "$ROOT/docs/appstore/screenshots"

echo "done → $OUT + docs/appstore/screenshots"
ls -la "$OUT" "$ROOT/docs/appstore/screenshots"
