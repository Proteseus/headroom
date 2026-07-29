#!/usr/bin/env bash
# Print the CHANGELOG.md section for a version, or fail if it has none.
#
#   ./scripts/changelog-section.sh            # section for host/VERSION
#   ./scripts/changelog-section.sh 1.0.9      # section for a specific version
#
# One source of truth for two callers that must agree: cut-release.sh gates a
# local tag on this, and the Release workflow gates an automatic tag on it and
# then uses the output as the GitHub Release body. A version nobody documented
# is a release nobody can read, and on the automatic path there is no human at
# a terminal to notice.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGELOG="$ROOT/CHANGELOG.md"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  # shellcheck source=version-env.sh
  source "$ROOT/scripts/version-env.sh"
  VERSION="$HEADROOM_VERSION"
fi

[[ -f "$CHANGELOG" ]] || { echo "error: missing $CHANGELOG" >&2; exit 1; }

# From "## <version>" up to (not including) the next "## " heading. The version
# is matched literally — 1.0.1 must not match the 1.0.10 heading.
SECTION="$(awk -v want="$VERSION" '
  /^## / {
    if (found) exit
    line = $0
    sub(/^## /, "", line)
    split(line, parts, / /)
    if (parts[1] == want) { found = 1; next }
    next
  }
  found { print }
' "$CHANGELOG")"

# Strip leading/trailing blank lines.
SECTION="$(printf '%s\n' "$SECTION" | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"

if [[ -z "$SECTION" ]]; then
  echo "error: CHANGELOG.md has no '## $VERSION' section (or it is empty)" >&2
  exit 1
fi

printf '%s\n' "$SECTION"
