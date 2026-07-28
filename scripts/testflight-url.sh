#!/usr/bin/env bash
# Print the iOS TestFlight URL from docs/install-links.md (empty if unset).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINKS="$ROOT/docs/install-links.md"
[[ -f "$LINKS" ]] || exit 0
awk -F'|' '
  /iOS TestFlight/ {
    url=$3
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", url)
    # Ignore markdown table separator leftovers / empty cells
    if (url ~ /^https?:\/\//) print url
    exit
  }
' "$LINKS"
