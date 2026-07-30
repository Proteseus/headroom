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

command -v xcodebuild >/dev/null || { echo "error: Xcode CLT / Xcode required" >&2; exit 1; }

"$ROOT/scripts/gen-project.sh"

cd "$ROOT/macos"

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
WIDGET_ENTITLEMENTS="$ROOT/widget/macos/HeadroomWidget.entitlements"
WIDGET="$APP/Contents/PlugIns/HeadroomWidget.appex"

# Xcode expands $(TeamIdentifierPrefix) in entitlements when it signs; codesign
# does not, and an app group whose id is a literal build setting grants nothing.
# Write a copy with the real team id in place, and hand codesign that.
#
# The prefix is a team id followed by a period — the group name already carries
# its own separator, so the substitution must not add a second one.
expanded_entitlements() {
  local source="$1"
  local team="$2"
  local out
  out="$(mktemp -t headroom-entitlements)"
  sed "s/\$(TeamIdentifierPrefix)/${team}./g" "$source" > "$out"
  printf '%s' "$out"
}

# Multi-Mac's CloudKit entitlements, but only when a profile authorizes them.
#
# `com.apple.developer.*` is the restricted family. codesign does not check
# them against anything, so a build that stamps them on with no embedded
# provisioning profile signs cleanly, notarizes, downloads — and is killed the
# moment it launches. Silent until it is in someone's Applications folder.
#
# So the rule is: no profile, no iCloud keys, and the artifact is exactly the
# one that shipped before this feature existed.
embed_icloud_profile() {
  local app_ents="$1"
  local profile="${HEADROOM_PROVISION_PROFILE:-}"
  if [[ -z "$profile" ]]; then
    echo "note: no HEADROOM_PROVISION_PROFILE — multi-Mac CloudKit is off in this build" >&2
    return 0
  fi
  if [[ ! -f "$profile" ]]; then
    echo "error: HEADROOM_PROVISION_PROFILE is set but $profile does not exist" >&2
    exit 1
  fi
  cp "$profile" "$APP/Contents/embedded.provisionprofile"
  /usr/libexec/PlistBuddy -c "Merge $ROOT/macos/Headroom-iCloud.entitlements" \
    "$app_ents" >/dev/null

  # Xcode copies these three out of the profile when it signs. codesign does
  # not — it stamps exactly what the plist holds and nothing else — so a
  # hand-signed bundle carries the container identifier with no application
  # identity to bind it to. CloudKit's answer to that is
  #
  #   "Trying to initialize a container without an application ID"
  #
  # which names the missing key without saying where it should have come from.
  # 1.2.2 shipped exactly that way: entitled for iCloud by every check we had,
  # and unable to open the container on any Mac.
  #
  # Read them off the profile rather than hardcoding, so they cannot disagree
  # with the profile that authorizes them. The environment matters as much as
  # the identifier — a Developer ID profile is Production, and without the key
  # CloudKit has nothing telling it which side of the container to talk to.
  local decoded value
  decoded="$(mktemp -t headroom-profile)"
  if ! security cms -D -i "$profile" > "$decoded" 2>/dev/null; then
    echo "error: $profile is not a readable provisioning profile" >&2
    rm -f "$decoded"
    exit 1
  fi
  for key in com.apple.application-identifier \
             com.apple.developer.team-identifier \
             com.apple.developer.icloud-container-environment; do
    value="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:$key" "$decoded" \
      2>/dev/null || true)"
    if [[ -z "$value" ]]; then
      echo "error: profile carries no $key — it cannot authorize CloudKit" >&2
      rm -f "$decoded"
      exit 1
    fi
    /usr/libexec/PlistBuddy -c "Delete :$key" "$app_ents" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$app_ents" >/dev/null
  done
  rm -f "$decoded"

  echo "note: embedded $(basename "$profile") — multi-Mac CloudKit is on" >&2
}

# The team that will actually be on the signature. Prefer the one inside the
# identity — "Developer ID Application: Name (TEAMID)" — because an entitlement
# claiming a different team than the certificate is a group that grants nothing.
signing_team() {
  local identity="$1"
  local from_identity
  from_identity="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<< "$identity")"
  if [[ -n "$from_identity" ]]; then
    if [[ -n "${HEADROOM_TEAM_ID:-}" && "$from_identity" != "$HEADROOM_TEAM_ID" ]]; then
      echo "note: signing as $from_identity (HEADROOM_TEAM_ID is $HEADROOM_TEAM_ID)" >&2
    fi
    printf '%s' "$from_identity"
    return
  fi
  if [[ -z "${HEADROOM_TEAM_ID:-}" ]]; then
    echo "error: can't tell which team to put in the app group entitlement." >&2
    echo "  set HEADROOM_TEAM_ID, or use an identity ending in (TEAMID)" >&2
    exit 1
  fi
  printf '%s' "$HEADROOM_TEAM_ID"
}

# The app group as it ended up on a signature, or empty. One entry per bundle,
# so pulling the string out of the entitlements XML is enough.
signed_app_group() {
  codesign -d --entitlements - --xml "$1" 2>/dev/null \
    | sed -n 's/.*<string>\([A-Z0-9]*\.group\.[^<]*\)<\/string>.*/\1/p'
}

sign_adhoc() {
  # Ad-hoc has no team, so the app group is dead either way — the widget falls
  # back to its placeholder on a locally built .app. Run from Xcode (automatic
  # signing, your own team) to see it draw real numbers.
  codesign --force --sign - "$WIDGET" 2>/dev/null || true
  codesign --force --sign - "$APP" 2>/dev/null || true
}

sign_developer_id() {
  local identity="${HEADROOM_SIGN_IDENTITY:-}"
  if [[ -z "$identity" ]]; then
    echo "error: HEADROOM_SIGN_IDENTITY required for --notarize" >&2
    echo "  e.g. export HEADROOM_SIGN_IDENTITY='Developer ID Application: Name (TEAMID)'" >&2
    exit 1
  fi

  # Inside out, never --deep: the widget is sandboxed and the app is not, so
  # they take different entitlements. --deep would stamp the app's onto the
  # extension and the sandbox would deny it the group container.
  local team widget_ents app_ents
  team="$(signing_team "$identity")"
  widget_ents="$(expanded_entitlements "$WIDGET_ENTITLEMENTS" "$team")"
  app_ents="$(expanded_entitlements "$ENTITLEMENTS" "$team")"
  # Before any codesign call: the profile lands inside the bundle, so it has to
  # be there when the bundle is sealed.
  embed_icloud_profile "$app_ents"

  if [[ -d "$WIDGET" ]]; then
    codesign --force --options runtime --timestamp \
      --sign "$identity" \
      --entitlements "$widget_ents" \
      "$WIDGET"
  else
    echo "error: missing $WIDGET — the widget extension did not embed" >&2
    exit 1
  fi

  # No nested frameworks — sign the main binary, then the bundle.
  local main_bin="$APP/Contents/MacOS/Headroom"
  [[ -f "$main_bin" ]] || { echo "error: missing $main_bin" >&2; exit 1; }
  codesign --force --options runtime --timestamp \
    --sign "$identity" \
    --entitlements "$app_ents" \
    "$main_bin"
  codesign --force --options runtime --timestamp \
    --sign "$identity" \
    --entitlements "$app_ents" \
    "$APP"
  rm -f "$widget_ents" "$app_ents"

  codesign --verify --deep --strict --verbose=2 "$APP"
  # A group that doesn't match between the two is the failure that looks like a
  # working build: the widget installs, loads, and draws the placeholder for
  # ever. Cheaper to catch here than in Notification Center.
  local app_group widget_group
  app_group="$(signed_app_group "$APP")"
  widget_group="$(signed_app_group "$WIDGET")"
  if [[ -z "$app_group" || "$app_group" != "$widget_group" ]]; then
    echo "error: app group mismatch after signing" >&2
    echo "  app:    ${app_group:-<none>}" >&2
    echo "  widget: ${widget_group:-<none>}" >&2
    exit 1
  fi
  echo "  app group: $app_group"
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
