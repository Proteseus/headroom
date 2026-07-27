#!/usr/bin/env bash
# Build a distributable HeadroomBar.app with the Python host embedded.
#
#   ./scripts/build-app.sh              # → dist/HeadroomBar.app + .zip
#   ./scripts/build-app.sh --release    # Release configuration
#
# Requires: Xcode, xcodegen, python3, rsync.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG=Debug
for arg in "$@"; do
  case "$arg" in
    --release) CONFIG=Release ;;
    --debug) CONFIG=Debug ;;
    -h|--help)
      cat <<'EOF'
Build HeadroomBar.app with the Python host embedded.

  ./scripts/build-app.sh           # Debug (default)
  ./scripts/build-app.sh --release # Release
EOF
      exit 0
      ;;
  esac
done

command -v xcodegen >/dev/null || { echo "error: install xcodegen (brew install xcodegen)" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "error: Xcode CLT / Xcode required" >&2; exit 1; }

"$ROOT/scripts/sync-embedded-host.sh"

cd "$ROOT/macos"
xcodegen generate

DERIVED="$ROOT/macos/.build"
if [[ "$CONFIG" == "Release" ]]; then
  DERIVED="$ROOT/macos/.build-release"
fi

xcodebuild \
  -project HeadroomBar.xcodeproj \
  -scheme HeadroomBar \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_SRC=$(find "$DERIVED/Build/Products/$CONFIG" -maxdepth 1 -name 'HeadroomBar.app' | head -1)
[[ -n "$APP_SRC" && -d "$APP_SRC" ]] || { echo "error: HeadroomBar.app not found under $DERIVED" >&2; exit 1; }

HOST_PY=""
for cand in \
  "$APP_SRC/Contents/Resources/host/headroom_server.py" \
  "$APP_SRC/Contents/Resources/EmbeddedHost/headroom_server.py"
do
  if [[ -f "$cand" ]]; then HOST_PY="$cand"; break; fi
done
[[ -n "$HOST_PY" ]] || {
  echo "error: bundled host missing under $APP_SRC/Contents/Resources" >&2
  find "$APP_SRC/Contents" -maxdepth 4 -type d >&2 || true
  exit 1
}

DIST="$ROOT/dist"
rm -rf "$DIST"
mkdir -p "$DIST"
ditto "$APP_SRC" "$DIST/HeadroomBar.app"
codesign --force --deep --sign - "$DIST/HeadroomBar.app" 2>/dev/null || true

ZIP="$DIST/HeadroomBar-macos.zip"
ditto -c -k --sequesterRsrc --keepParent "$DIST/HeadroomBar.app" "$ZIP"

HOST_COUNT=$(find "$DIST/HeadroomBar.app/Contents/Resources" -name 'headroom_server.py' | head -1 | xargs -I{} dirname {} | xargs -I{} find {} -name '*.py' | wc -l | tr -d ' ')

echo
echo "Built ($CONFIG):"
echo "  $DIST/HeadroomBar.app"
echo "  $ZIP"
echo "  bundled host: $HOST_PY ($HOST_COUNT modules)"
echo
echo "Open the app, click the menu bar icon, and tap Start host on first launch."
