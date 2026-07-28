#!/usr/bin/env bash
# Archive HeadroomMobile (+ widget) and optionally upload to TestFlight.
#
#   ./scripts/build-ios.sh                 # archive + export IPA → dist/
#   ./scripts/build-ios.sh --upload        # also upload via App Store Connect API
#
# Versioning matches macOS (scripts/version-env.sh).
#
# Upload env:
#   APPLE_API_KEY_PATH / APPLE_API_KEY
#   APPLE_API_KEY_ID
#   APPLE_API_ISSUER_ID
#
# Requires: Xcode, xcodegen, signing set up for team 992N457T8D,
# and an App Store Connect app for com.centaur-labs.headroom (create once in ASC).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=version-env.sh
source "$ROOT/scripts/version-env.sh"

UPLOAD=0
for arg in "$@"; do
  case "$arg" in
    --upload) UPLOAD=1 ;;
    -h|--help)
      cat <<'EOF'
Archive HeadroomMobile for App Store / TestFlight.

  ./scripts/build-ios.sh          # → dist/Headroom-iOS.ipa
  ./scripts/build-ios.sh --upload # export + upload to App Store Connect
EOF
      exit 0
      ;;
    *)
      echo "error: unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

command -v xcodegen >/dev/null || { echo "error: install xcodegen (brew install xcodegen)" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "error: Xcode required" >&2; exit 1; }

"$ROOT/scripts/sync-embedded-host.sh"

cd "$ROOT/macos"
xcodegen generate

DERIVED="$ROOT/macos/.build-ios"
ARCHIVE="$DERIVED/HeadroomMobile.xcarchive"
EXPORT_DIR="$DERIVED/export"
DIST="$ROOT/dist"
EXPORT_OPTIONS="$ROOT/ios/ExportOptions.plist"

rm -rf "$DERIVED"
mkdir -p "$DERIVED" "$DIST"

VERSION_ARGS=(
  "MARKETING_VERSION=$HEADROOM_VERSION"
  "CURRENT_PROJECT_VERSION=$HEADROOM_BUILD"
  "DEVELOPMENT_TEAM=992N457T8D"
)

echo "Archiving HeadroomMobile $HEADROOM_VERSION ($HEADROOM_BUILD)"

# Optional ASC API key → Xcode can refresh provisioning profiles on CI.
AUTH_ARGS=()
key_path="${APPLE_API_KEY_PATH:-}"
key_id="${APPLE_API_KEY_ID:-}"
issuer="${APPLE_API_ISSUER_ID:-}"
tmp_auth_key=""
if [[ -n "$key_id" && -n "$issuer" ]]; then
  if [[ -z "$key_path" && -n "${APPLE_API_KEY:-}" ]]; then
    tmp_auth_key="$(mktemp -t AuthKey).p8"
    printf '%s\n' "$APPLE_API_KEY" > "$tmp_auth_key"
    key_path="$tmp_auth_key"
  fi
  if [[ -n "$key_path" ]]; then
    AUTH_ARGS=(
      -allowProvisioningUpdates
      -authenticationKeyPath "$key_path"
      -authenticationKeyID "$key_id"
      -authenticationKeyIssuerID "$issuer"
    )
  fi
fi

xcodebuild archive \
  -project Headroom.xcodeproj \
  -scheme HeadroomMobile \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DERIVED/DerivedData" \
  "${VERSION_ARGS[@]}" \
  "${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  "${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}"

IPA=$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' | head -1)
[[ -n "$IPA" && -f "$IPA" ]] || {
  echo "error: no IPA under $EXPORT_DIR" >&2
  ls -la "$EXPORT_DIR" >&2 || true
  exit 1
}

cp "$IPA" "$DIST/Headroom-iOS.ipa"
cat > "$DIST/ios-version.txt" <<EOF
version=$HEADROOM_VERSION
build=$HEADROOM_BUILD
bundle=com.centaur-labs.headroom
EOF

echo "Exported $DIST/Headroom-iOS.ipa ($HEADROOM_VERSION+$HEADROOM_BUILD)"

if [[ "$UPLOAD" -eq 0 ]]; then
  [[ -n "$tmp_auth_key" ]] && rm -f "$tmp_auth_key"
  exit 0
fi

if [[ -z "$key_id" || -z "$issuer" ]]; then
  echo "error: APPLE_API_KEY_ID and APPLE_API_ISSUER_ID required for --upload" >&2
  exit 1
fi

# altool looks in ~/.appstoreconnect/private_keys/AuthKey_<id>.p8
mkdir -p "$HOME/.appstoreconnect/private_keys"
altool_key="$HOME/.appstoreconnect/private_keys/AuthKey_${key_id}.p8"
if [[ ! -f "$altool_key" ]]; then
  if [[ -n "$key_path" && -f "$key_path" ]]; then
    cp "$key_path" "$altool_key"
  elif [[ -n "${APPLE_API_KEY:-}" ]]; then
    printf '%s\n' "$APPLE_API_KEY" > "$altool_key"
  else
    echo "error: set APPLE_API_KEY_PATH or APPLE_API_KEY for --upload" >&2
    exit 1
  fi
  chmod 600 "$altool_key"
fi

echo "Uploading to App Store Connect (TestFlight)…"
xcrun altool --upload-app \
  --type ios \
  --file "$DIST/Headroom-iOS.ipa" \
  --apiKey "$key_id" \
  --apiIssuer "$issuer" \
  --verbose

[[ -n "$tmp_auth_key" ]] && rm -f "$tmp_auth_key"

echo "Upload submitted. Processing in App Store Connect may take a few minutes."
