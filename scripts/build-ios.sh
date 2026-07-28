#!/usr/bin/env bash
# Archive HeadroomMobile (+ widget) and optionally upload to TestFlight.
#
#   ./scripts/build-ios.sh                 # archive + export IPA → dist/
#   ./scripts/build-ios.sh --upload        # export + asc publish testflight
#
# Versioning matches macOS (scripts/version-env.sh).
#
# Upload env:
#   APPLE_API_KEY_PATH / APPLE_API_KEY
#   APPLE_API_KEY_ID
#   APPLE_API_ISSUER_ID
#   ASC_APP_ID              App Store Connect app id (6795549853)
#   ASC_TESTFLIGHT_GROUP    group name or id (default: Internal)
#
# Requires: Xcode, xcodegen, asc (brew install asc), team 992N457T8D,
# and an App Store Connect app for com.centaur-labs.headroom.
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
  ./scripts/build-ios.sh --upload # export + asc publish → Internal group
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

app_id="${ASC_APP_ID:-}"
group="${ASC_TESTFLIGHT_GROUP:-Internal}"
if [[ -z "$app_id" ]]; then
  echo "error: ASC_APP_ID required for --upload (App Store Connect app id)" >&2
  exit 1
fi
if [[ -z "$key_id" || -z "$issuer" ]]; then
  echo "error: APPLE_API_KEY_ID and APPLE_API_ISSUER_ID required for --upload" >&2
  exit 1
fi
if [[ -z "$key_path" || ! -f "$key_path" ]]; then
  echo "error: set APPLE_API_KEY_PATH or APPLE_API_KEY for --upload" >&2
  exit 1
fi
command -v asc >/dev/null || {
  echo "error: install asc (brew install asc) for TestFlight upload" >&2
  exit 1
}

# Prefer env auth so CI does not need a keychain profile.
export ASC_KEY_ID="$key_id"
export ASC_ISSUER_ID="$issuer"
export ASC_PRIVATE_KEY_PATH="$key_path"
export ASC_BYPASS_KEYCHAIN=true
export ASC_APP_ID="$app_id"

echo "Publishing to TestFlight (app $app_id → group $group)…"
asc publish testflight \
  --app "$app_id" \
  --ipa "$DIST/Headroom-iOS.ipa" \
  --group "$group" \
  --wait \
  --notify \
  --output table

[[ -n "$tmp_auth_key" ]] && rm -f "$tmp_auth_key"

echo "TestFlight publish finished ($HEADROOM_VERSION+$HEADROOM_BUILD → $group)."
