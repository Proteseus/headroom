#!/usr/bin/env bash
# One-shot: install the just-built 1.8.0 Release Headroom over /Applications
# and repoint the LaunchAgent host at it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/macos/.build-release/Build/Products/Release/Headroom.app"
DIST="$ROOT/dist/Headroom.app"
DEST="/Applications/Headroom.app"
UID_NUM="$(id -u)"
LABEL="gui/${UID_NUM}/com.centaur-labs.headroom"

[[ -d "$SRC" ]] || { echo "missing $SRC — build Release first"; exit 1; }

echo "Preparing dist…"
rm -rf "$DIST"
ditto "$SRC" "$DIST"
codesign --force --deep --sign - "$DIST" >/dev/null

echo "Quitting Headroom…"
osascript -e 'tell application "Headroom" to quit' >/dev/null 2>&1 || true
sleep 1
killall Headroom 2>/dev/null || true
sleep 1

echo "Stopping LaunchAgent…"
launchctl bootout "$LABEL" 2>/dev/null || true
sleep 2

echo "Installing to $DEST…"
rm -rf "$DEST"
ditto "$DIST" "$DEST"
codesign --force --deep --sign - "$DEST" >/dev/null

echo "Repointing host…"
"$ROOT/scripts/install-host.sh" --app="$DEST" || true
sleep 2
if ! launchctl print "$LABEL" >/dev/null 2>&1; then
  echo "retrying bootstrap…"
  sleep 3
  launchctl bootstrap "gui/${UID_NUM}" "$HOME/Library/LaunchAgents/com.centaur-labs.headroom.plist"
  sleep 2
fi

echo "Launching…"
open "$DEST"
sleep 1

echo
echo "Installed:"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEST/Contents/Info.plist"
echo "OpenRouter should now show a depletion bar, not a ring."
