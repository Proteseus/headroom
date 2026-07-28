#!/usr/bin/env bash
# Build a distributable Headroom.app with the Python host embedded.
#
#   ./scripts/build-app.sh                 # Debug → dist/ (ad-hoc sign)
#   ./scripts/build-app.sh --release       # Release config, ad-hoc sign
#   ./scripts/build-app.sh --release --notarize
#       Developer ID sign + notarytool + staple (CI / local with certs)
#
# Versioning (see scripts/version-env.sh):
#   MARKETING_VERSION  ← host/VERSION
#   CURRENT_PROJECT_VERSION ← git rev-list --count HEAD
#
# Notarize env (required with --notarize):
#   HEADROOM_SIGN_IDENTITY   e.g. "Developer ID Application: … (TEAMID)"
#   APPLE_API_KEY_PATH       path to AuthKey_XXXX.p8  (or APPLE_API_KEY contents)
#   APPLE_API_KEY_ID
#   APPLE_API_ISSUER_ID
#
# Requires: Xcode, xcodegen, python3, rsync.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=version-env.sh
source "$ROOT/scripts/version-env.sh"

CONFIG=Debug
NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --release) CONFIG=Release ;;
    --debug) CONFIG=Debug ;;
    --notarize) NOTARIZE=1 ;;
    -h|--help)
      cat <<'EOF'
Build Headroom.app with the Python host embedded.

  ./scripts/build-app.sh                    # Debug (default)
  ./scripts/build-app.sh --release          # Release, ad-hoc sign
  ./scripts/build-app.sh --release --notarize
                                            # Developer ID + notarize + staple

Versions come from host/VERSION + git commit count (scripts/version-env.sh).
EOF
      exit 0
      ;;
    *)
      echo "error: unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

if [[ "$NOTARIZE" -eq 1 && "$CONFIG" != "Release" ]]; then
  echo "error: --notarize requires --release" >&2
  exit 1
fi

command -v xcodegen >/dev/null || { echo "error: install xcodegen (brew install xcodegen)" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "error: Xcode CLT / Xcode required" >&2; exit 1; }

"$ROOT/scripts/sync-embedded-host.sh"

cd "$ROOT/macos"
xcodegen generate

DERIVED="$ROOT/macos/.build"
if [[ "$CONFIG" == "Release" ]]; then
  DERIVED="$ROOT/macos/.build-release"
fi

VERSION_ARGS=(
  "MARKETING_VERSION=$HEADROOM_VERSION"
  "CURRENT_PROJECT_VERSION=$HEADROOM_BUILD"
)

echo "Building Headroom $HEADROOM_VERSION ($HEADROOM_BUILD) [$CONFIG]"

xcodebuild \
  -project Headroom.xcodeproj \
  -scheme Headroom \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  "${VERSION_ARGS[@]}" \
  build

APP_SRC=$(find "$DERIVED/Build/Products/$CONFIG" -maxdepth 1 -name 'Headroom.app' | head -1)
[[ -n "$APP_SRC" && -d "$APP_SRC" ]] || { echo "error: Headroom.app not found under $DERIVED" >&2; exit 1; }

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
ditto "$APP_SRC" "$DIST/Headroom.app"
APP="$DIST/Headroom.app"
ENTITLEMENTS="$ROOT/macos/Headroom.entitlements"

sign_adhoc() {
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
}

sign_developer_id() {
  local identity="${HEADROOM_SIGN_IDENTITY:-}"
  if [[ -z "$identity" ]]; then
    echo "error: HEADROOM_SIGN_IDENTITY required for --notarize" >&2
    echo "  e.g. export HEADROOM_SIGN_IDENTITY='Developer ID Application: Name (TEAMID)'" >&2
    exit 1
  fi
  # No nested frameworks — sign the main binary, then the bundle.
  local main_bin="$APP/Contents/MacOS/Headroom"
  [[ -f "$main_bin" ]] || { echo "error: missing $main_bin" >&2; exit 1; }
  codesign --force --options runtime --timestamp \
    --sign "$identity" \
    --entitlements "$ENTITLEMENTS" \
    "$main_bin"
  codesign --force --options runtime --timestamp \
    --sign "$identity" \
    --entitlements "$ENTITLEMENTS" \
    "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
}

notarize_and_staple() {
  local key_path="${APPLE_API_KEY_PATH:-}"
  local key_id="${APPLE_API_KEY_ID:-}"
  local issuer="${APPLE_API_ISSUER_ID:-}"

  if [[ -z "$key_id" || -z "$issuer" ]]; then
    echo "error: APPLE_API_KEY_ID and APPLE_API_ISSUER_ID required for --notarize" >&2
    exit 1
  fi

  local tmp_key=""
  if [[ -z "$key_path" ]]; then
    if [[ -z "${APPLE_API_KEY:-}" ]]; then
      echo "error: set APPLE_API_KEY_PATH or APPLE_API_KEY (.p8 contents) for --notarize" >&2
      exit 1
    fi
    tmp_key="$(mktemp -t AuthKey).p8"
    printf '%s\n' "$APPLE_API_KEY" > "$tmp_key"
    key_path="$tmp_key"
  fi

  local submit_zip="$DIST/Headroom-notarize.zip"
  ditto -c -k --keepParent "$APP" "$submit_zip"

  echo "Submitting to Apple notarization…"
  xcrun notarytool submit "$submit_zip" \
    --key "$key_path" \
    --key-id "$key_id" \
    --issuer "$issuer" \
    --wait

  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -f "$submit_zip"
  [[ -n "$tmp_key" ]] && rm -f "$tmp_key"
}

if [[ "$NOTARIZE" -eq 1 ]]; then
  sign_developer_id
  notarize_and_staple
else
  sign_adhoc
fi

ZIP="$DIST/Headroom-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# Companion metadata for CI / release notes
cat > "$DIST/version.txt" <<EOF
version=$HEADROOM_VERSION
build=$HEADROOM_BUILD
config=$CONFIG
notarized=$NOTARIZE
EOF

HOST_COUNT=$(find "$APP/Contents/Resources" -name 'headroom_server.py' | head -1 | xargs -I{} dirname {} | xargs -I{} find {} -name '*.py' | wc -l | tr -d ' ')

echo
echo "Built ($CONFIG) $HEADROOM_VERSION+$HEADROOM_BUILD:"
echo "  $APP"
echo "  $ZIP"
echo "  bundled host: $HOST_PY ($HOST_COUNT modules)"
if [[ "$NOTARIZE" -eq 1 ]]; then
  echo "  notarized + stapled"
else
  echo "  signed ad-hoc (Gatekeeper will warn until --notarize)"
fi
echo
echo "Open the app and click the menu bar icon — Welcome starts the host automatically on a Release build."
