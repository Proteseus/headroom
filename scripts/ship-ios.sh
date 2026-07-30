#!/usr/bin/env bash
# Put the released version on TestFlight from this Mac.
#
#   ./scripts/ship-ios.sh             # archive, export, upload
#   ./scripts/ship-ios.sh --dry-run   # stop after dist/Headroom-iOS.ipa
#
# Prefer the Release workflow when secrets are set: it archives with
# --manual-signing (Distribution + named App Store profiles). This script is
# the laptop path when you want the signed-in Xcode account to manage profiles.
#
# Signing here comes from the Xcode account on this Mac, which already has the
# Apple Distribution certificate. So the ASC key is deliberately kept out of
# the archive: xcodebuild gets -allowProvisioningUpdates and nothing else, and
# `asc` uploads under its own stored credential.
#
# ## Lockstep
#
# Both numbers Apple sees are derived from the commit, not from this script:
#
#   CFBundleShortVersionString   host/VERSION
#   CFBundleVersion              git rev-list --count HEAD
#
# One commit further along and the build number moves, so an upload from a
# dirty tree or from past the tag lands a build on TestFlight that matches no
# GitHub Release, and nothing downstream can take it back. The guards below
# refuse rather than ship something untraceable — run this at the release
# commit, in a clean tree, and TestFlight gets exactly what the Release did.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,5p' "$0"
      exit 0
      ;;
    *)
      echo "error: unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }

cd "$ROOT"

# shellcheck source=version-env.sh
source "$ROOT/scripts/version-env.sh"
TAG="v$HEADROOM_VERSION"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is dirty — the upload would carry uncommitted work" >&2
  echo "       under $TAG's number, which no Release can account for." >&2
  echo >&2
  git status --short >&2
  echo >&2
  echo "Ship from a worktree at the tag instead:" >&2
  echo "  git worktree add --detach /tmp/ship $TAG" >&2
  exit 1
fi

git fetch --tags --quiet origin 2>/dev/null || true

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
  || die "$TAG does not exist yet — host/VERSION is $HEADROOM_VERSION but nothing
       has shipped under it. Push the bump, let Release publish, then run this."

TAGGED="$(git rev-parse "refs/tags/$TAG^{commit}")"
HEAD_SHA="$(git rev-parse HEAD)"
if [[ "$TAGGED" != "$HEAD_SHA" ]]; then
  echo "error: HEAD is not $TAG, so the build number would not match the release." >&2
  echo "       $TAG   $TAGGED" >&2
  echo "       HEAD   $HEAD_SHA" >&2
  echo >&2
  echo "  git worktree add --detach /tmp/ship $TAG" >&2
  exit 1
fi

# The iPhone app embeds the watch app, and stable Xcode resolves every watchOS
# destination to "watchOS 26.5 is not installed" (AGENTS.md).
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-beta.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

# CI's key would take over provisioning from the Xcode account and fail the
# export the same way it does on the runner. `asc` keeps its own credential.
unset APPLE_API_KEY APPLE_API_KEY_PATH APPLE_API_KEY_ID APPLE_API_ISSUER_ID

echo "Shipping Headroom $HEADROOM_VERSION+$HEADROOM_BUILD ($TAG) to TestFlight"
echo "  team     $HEADROOM_TEAM_ID"
echo "  xcode    ${DEVELOPER_DIR:-$(xcode-select -p)}"
echo

if [[ "$DRY_RUN" -eq 1 ]]; then
  "$ROOT/scripts/build-ios.sh"
  echo
  echo "Dry run — dist/Headroom-iOS.ipa built, nothing uploaded."
  exit 0
fi

"$ROOT/scripts/build-ios.sh" --upload

TF="$("$ROOT/scripts/testflight-url.sh" 2>/dev/null || true)"
if [[ -n "$TF" ]]; then
  echo
  echo "Testers install from $TF"
fi
