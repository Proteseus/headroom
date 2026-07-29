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
# Requires: Xcode, xcodegen, asc (brew install asc), and an App Store Connect
# app. Signs as $HEADROOM_TEAM_ID (default: the maintainer's team) against
# com.centaur-labs.headroom — forks export their own team and bundle id.
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

command -v xcodebuild >/dev/null || { echo "error: Xcode required" >&2; exit 1; }

"$ROOT/scripts/gen-project.sh"

cd "$ROOT/macos"

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
  "DEVELOPMENT_TEAM=$HEADROOM_TEAM_ID"
)

# ios/ExportOptions.plist carries the maintainer's team and profile names. Sign
# as whoever $HEADROOM_TEAM_ID says; a fork also swaps the profile names for
# its own (see CONTRIBUTING.md).
EXPORT_OPTIONS_RESOLVED="$DERIVED/ExportOptions.plist"
cp "$EXPORT_OPTIONS" "$EXPORT_OPTIONS_RESOLVED"
/usr/libexec/PlistBuddy -c "Set :teamID $HEADROOM_TEAM_ID" \
  "$EXPORT_OPTIONS_RESOLVED"

echo "Archiving HeadroomMobile $HEADROOM_VERSION ($HEADROOM_BUILD)"

# Let Xcode mint the missing App Store profiles either way. On CI that needs
# the ASC key appended below; on a Mac with an Apple Distribution certificate
# the signed-in Xcode account does it, and passing a key would override the
# account with something weaker (see scripts/ship-ios.sh).
AUTH_ARGS=(-allowProvisioningUpdates)
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
    AUTH_ARGS+=(
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
  -exportOptionsPlist "$EXPORT_OPTIONS_RESOLVED" \
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

# Defaults to the maintainer's App Store Connect app, same as $HEADROOM_TEAM_ID
# defaults to their team; a fork exports its own.
app_id="${ASC_APP_ID:-6795549853}"
group="${ASC_TESTFLIGHT_GROUP:-Internal}"
command -v asc >/dev/null || {
  echo "error: install asc (brew install asc) for TestFlight upload" >&2
  exit 1
}

if [[ -n "$key_id" && -n "$issuer" && -n "$key_path" && -f "$key_path" ]]; then
  # Prefer env auth so CI does not need a keychain profile.
  export ASC_KEY_ID="$key_id"
  export ASC_ISSUER_ID="$issuer"
  export ASC_PRIVATE_KEY_PATH="$key_path"
  export ASC_BYPASS_KEYCHAIN=true
elif ! asc auth status 2>/dev/null | grep -q '"keyId"'; then
  # No key in the environment and nothing in the keychain either. `asc auth
  # status` exits 0 with an empty credential list, so match on the list.
  echo "error: no App Store Connect credentials for --upload — set" >&2
  echo "       APPLE_API_KEY_ID + APPLE_API_ISSUER_ID + APPLE_API_KEY_PATH," >&2
  echo "       or store one with 'asc auth add' (see docs/releasing.md)" >&2
  exit 1
fi
export ASC_APP_ID="$app_id"

echo "Publishing to TestFlight (app $app_id → group $group)…"
# Upload + wait first, then mark export-compliance exempt and attach groups.
# `asc publish testflight` can race before the build is assignable when encryption
# compliance is still unanswered.
asc builds upload \
  --app "$app_id" \
  --ipa "$DIST/Headroom-iOS.ipa" \
  --wait \
  --output table
asc builds update \
  --app "$app_id" \
  --latest \
  --uses-non-exempt-encryption=false \
  --output table
asc builds add-groups \
  --app "$app_id" \
  --latest \
  --group "$group" \
  --output table

[[ -n "$tmp_auth_key" ]] && rm -f "$tmp_auth_key"

echo "TestFlight publish finished ($HEADROOM_VERSION+$HEADROOM_BUILD → $group)."
