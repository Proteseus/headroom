#!/usr/bin/env bash
# Tag the current host/VERSION and push so .github/workflows/release.yml runs.
#
#   ./scripts/cut-release.sh           # tag + push origin
#   ./scripts/cut-release.sh --dry-run # print what would happen
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=version-env.sh
source "$ROOT/scripts/version-env.sh"

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

TAG="v$HEADROOM_VERSION"
LINKS="$ROOT/docs/install-links.md"

die() { echo "error: $*" >&2; exit 1; }

command -v git >/dev/null || die "git required"
cd "$ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
  die "working tree dirty — commit or stash before cutting $TAG"
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  die "tag $TAG already exists"
fi

TESTFLIGHT="$(
  awk -F'|' '
    /iOS TestFlight/ {
      url=$3
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", url)
      print url
      exit
    }
  ' "$LINKS" 2>/dev/null || true
)"

echo "Headroom $HEADROOM_VERSION (build $HEADROOM_BUILD) → tag $TAG"
if [[ -z "$TESTFLIGHT" ]]; then
  echo "note: docs/install-links.md has no TestFlight URL yet — release notes will say build from source."
else
  echo "TestFlight: $TESTFLIGHT"
fi

if [[ "$DRY" -eq 1 ]]; then
  echo "(dry-run) would: git tag -a $TAG -m \"Headroom $HEADROOM_VERSION\" && git push origin $TAG"
  exit 0
fi

git tag -a "$TAG" -m "Headroom $HEADROOM_VERSION"
git push origin "$TAG"
echo
echo "Pushed $TAG. Watch: gh run watch --repo michellzappa/headroom"
echo "Release assets land on: https://github.com/michellzappa/headroom/releases/tag/$TAG"
