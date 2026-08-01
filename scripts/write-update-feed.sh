#!/usr/bin/env bash
# Write docs/latest.json — the feed a running Headroom.app polls to learn a
# newer one exists. See docs/updater.md.
#
#   ./scripts/write-update-feed.sh                 # feed for host/VERSION
#   ./scripts/write-update-feed.sh 1.4.2           # feed for a specific version
#   ./scripts/write-update-feed.sh --url https://…/Headroom-macOS.zip
#   ./scripts/write-update-feed.sh --out /tmp/f.json
#
# The zip is downloaded, not assumed. That is the point of doing it here rather
# than hashing dist/ in the build job: it proves the URL a shipped app will
# fetch actually resolves, and that what answers is the artifact we hashed. A
# feed advertising a 404 is worse than no feed, because the app stops asking.
#
# What is deliberately NOT in the feed: the expected Team ID. The app's only
# real defence is that scripts/update-app.sh refuses any bundle not notarized
# under a team it was compiled with. Shipping that team in the feed invites
# someone to read it from there one day, which would hand the check to whoever
# controls the feed. Same reason `sha256` below is an integrity check on the
# download and not an authenticity check on the release.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

REPO="${HEADROOM_GITHUB_REPO:-michellzappa/headroom}"
OUT="$ROOT/docs/latest.json"
URL=""
VERSION=""

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    -*) die "unknown argument: $1" ;;
    *) VERSION="$1"; shift ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  # shellcheck source=version-env.sh
  source "$ROOT/scripts/version-env.sh"
  VERSION="$HEADROOM_VERSION"
fi
VERSION="${VERSION#v}"
TAG="v$VERSION"

# Default to the GitHub Release asset. This is the one string that has to
# change the day the zip moves to a bucket, which is why the app reads it from
# the feed instead of building the path itself.
URL="${URL:-https://github.com/$REPO/releases/download/$TAG/Headroom-macOS.zip}"

# Fails the release rather than publishing a feed nobody can follow.
NOTES="$(NO_COLOR=1 "$ROOT/scripts/changelog-section.sh" "$VERSION")" \
  || die "no CHANGELOG.md section for $VERSION"

# GNU mktemp (used by the Linux release runner) requires a template with at
# least three trailing Xs; macOS accepts the same portable form.
STAGE="$(mktemp -d -t headroom-feed.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

# --retry-all-errors so a 404 is retried too: called straight after a release
# is published, the asset is routinely a few seconds behind the API that
# announced it, and that 404 is propagation rather than an answer.
echo "Fetching $URL …" >&2
curl -fsSL --proto '=https' --tlsv1.2 \
  --retry 5 --retry-delay 3 --retry-all-errors \
  -o "$STAGE/app.zip" "$URL" \
  || die "the release asset did not resolve: $URL"

# sha256sum on Linux, shasum on macOS — this runs in both places.
if command -v sha256sum >/dev/null 2>&1; then
  SHA="$(sha256sum "$STAGE/app.zip" | cut -d' ' -f1)"
else
  SHA="$(shasum -a 256 "$STAGE/app.zip" | cut -d' ' -f1)"
fi
# `wc -c` rather than stat, whose flags differ between the two.
SIZE="$(wc -c < "$STAGE/app.zip" | tr -d '[:space:]')"

mkdir -p "$(dirname "$OUT")"
VERSION="$VERSION" URL="$URL" SHA="$SHA" SIZE="$SIZE" NOTES="$NOTES" \
PUBLISHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
python3 - "$OUT" <<'PY'
import json, os, sys

# Key order is cosmetic, but a stable one keeps the release diff to the lines
# that actually moved. Additive only: see docs/updater.md — a build that cannot
# decode this is a build that can never be updated again.
doc = {
    "schema": 1,
    "version": os.environ["VERSION"],
    "published": os.environ["PUBLISHED"],
    "url": os.environ["URL"],
    "sha256": os.environ["SHA"],
    "size": int(os.environ["SIZE"]),
    "min_macos": "14.0",
    "notes_md": os.environ["NOTES"].rstrip("\n"),
}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY

echo "Wrote $OUT — $VERSION, $SIZE bytes, sha256 ${SHA:0:12}…" >&2
