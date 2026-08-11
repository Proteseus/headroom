#!/usr/bin/env bash
# One-shot: install a locally built Release Headroom over /Applications and
# repoint the LaunchAgent host at it.
#
# Takes `dist/Headroom.app` when `build-app.sh` has already signed one, and
# the raw build product otherwise. **A signature with a team is never
# replaced.** The widget's app group is `TEAMID.group.…`, read off its own
# signature at runtime, so ad-hoc re-signing a `--sign` build silently costs
# it the container and the widget draws its empty state for ever. That is
# also why `build-app.sh --release --sign` is the build to install when the
# thing being tested is the widget.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILT="$ROOT/macos/.build-release/Build/Products/Release/Headroom.app"
DIST="$ROOT/dist/Headroom.app"
DEST="/Applications/Headroom.app"
UID_NUM="$(id -u)"
LABEL="gui/${UID_NUM}/com.centaur-labs.headroom"

# The team on a bundle's signature, or empty for ad-hoc and unsigned.
signing_team() {
  codesign -dv --verbose=4 "$1" 2>&1 \
    | sed -n 's/^TeamIdentifier=\(.*\)$/\1/p' \
    | grep -v '^not set$' || true
}

if [[ -d "$DIST" && -n "$(signing_team "$DIST")" ]]; then
  echo "Using signed $DIST (team $(signing_team "$DIST"))"
else
  [[ -d "$BUILT" ]] || { echo "missing $BUILT — build Release first"; exit 1; }
  echo "Preparing dist…"
  rm -rf "$DIST"
  ditto "$BUILT" "$DIST"
  codesign --force --deep --sign - "$DIST" >/dev/null
  echo "note: ad-hoc signed — no team, so the widget cannot read the app" >&2
  echo "      group. Use build-app.sh --release --sign to test widgets." >&2
fi

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
# ditto carries the signature across, so there is nothing to re-sign — and
# re-signing here is what used to throw the team away.
ditto "$DIST" "$DEST"

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
