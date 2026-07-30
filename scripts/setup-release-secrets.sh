#!/usr/bin/env bash
# Push local signing / App Store Connect credentials into GitHub Actions secrets.
#
# Prerequisites:
#   - gh auth with repo admin (or a PAT that can write Actions secrets)
#   - Developer ID .p12 export
#   - App Store Connect API .p8 (AuthKey_XXXX.p8)
#
# Usage:
#   ./scripts/setup-release-secrets.sh \
#     --p12 ~/Desktop/DeveloperID.p12 \
#     --p12-password '…' \
#     --api-key ~/.appstoreconnect/private_keys/AuthKey_XXXX.p8 \
#     --api-key-id XXXX \
#     --api-issuer-id xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#
# Optional: --keychain-password 'random'  (defaults to a generated value)
# Optional: --provision-profile ~/Desktop/Headroom.provisionprofile
#           Developer ID profile for com.centaur-labs.headroom.macos with the
#           iCloud capability. Without it releases build fine and multi-Mac
#           over CloudKit is off in them (docs/multi-mac.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${HEADROOM_GITHUB_REPO:-michellzappa/headroom}"

P12=""
P12_PASSWORD=""
API_KEY=""
API_KEY_ID=""
API_ISSUER_ID=""
KEYCHAIN_PASSWORD=""
PROVISION_PROFILE=""

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --p12) P12="${2:-}"; shift 2 ;;
    --p12-password) P12_PASSWORD="${2:-}"; shift 2 ;;
    --api-key) API_KEY="${2:-}"; shift 2 ;;
    --api-key-id) API_KEY_ID="${2:-}"; shift 2 ;;
    --api-issuer-id) API_ISSUER_ID="${2:-}"; shift 2 ;;
    --keychain-password) KEYCHAIN_PASSWORD="${2:-}"; shift 2 ;;
    --provision-profile) PROVISION_PROFILE="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,24p' "$0"
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v gh >/dev/null || die "install gh (brew install gh)"
command -v base64 >/dev/null || die "base64 required"

[[ -n "$P12" && -f "$P12" ]] || die "--p12 path to Developer ID .p12 required"
[[ -n "$P12_PASSWORD" ]] || die "--p12-password required"
[[ -n "$API_KEY" && -f "$API_KEY" ]] || die "--api-key path to AuthKey_XXXX.p8 required"
[[ -n "$API_KEY_ID" ]] || die "--api-key-id required"
[[ -n "$API_ISSUER_ID" ]] || die "--api-issuer-id required (ASC → Users and Access → Integrations)"

if [[ -z "$KEYCHAIN_PASSWORD" ]]; then
  KEYCHAIN_PASSWORD="$(openssl rand -hex 16)"
fi

echo "Setting secrets on $REPO …"
base64 < "$P12" | gh secret set MACOS_CERTIFICATE_P12 --repo "$REPO"
printf '%s' "$P12_PASSWORD" | gh secret set MACOS_CERTIFICATE_PASSWORD --repo "$REPO"
printf '%s' "$KEYCHAIN_PASSWORD" | gh secret set KEYCHAIN_PASSWORD --repo "$REPO"
gh secret set APPLE_API_KEY --repo "$REPO" < "$API_KEY"
printf '%s' "$API_KEY_ID" | gh secret set APPLE_API_KEY_ID --repo "$REPO"
printf '%s' "$API_ISSUER_ID" | gh secret set APPLE_API_ISSUER_ID --repo "$REPO"

# Optional, and the release still works without it. Skipping only means the
# published app has no iCloud entitlement, so multi-Mac reports itself off.
# Merging those entitlements with no profile to authorize them would be the
# genuinely bad outcome: the app signs, notarizes, and dies at launch.
if [[ -n "$PROVISION_PROFILE" ]]; then
  [[ -f "$PROVISION_PROFILE" ]] || die "--provision-profile $PROVISION_PROFILE not found"
  security cms -D -i "$PROVISION_PROFILE" >/dev/null 2>&1 \
    || die "--provision-profile is not a provisioning profile"
  base64 < "$PROVISION_PROFILE" | gh secret set MACOS_PROVISION_PROFILE --repo "$REPO"
  echo "Set MACOS_PROVISION_PROFILE — multi-Mac CloudKit will be on from the next release."
else
  echo "No --provision-profile — multi-Mac CloudKit stays off in releases (docs/multi-mac.md)."
fi

echo
echo "Done. Verify with: gh secret list --repo $REPO"
echo "Next: fill docs/install-links.md TestFlight URL (after ASC public link),"
echo "then ./scripts/cut-release.sh"
