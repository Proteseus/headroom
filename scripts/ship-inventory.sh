#!/usr/bin/env bash
# Read-only ship queue for cleanup / release agents. Does not commit, bump, or push.
#
#   ./scripts/ship-inventory.sh
#   ./scripts/ship-inventory.sh --json   # machine-readable summary
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

JSON=0
[[ "${1:-}" == "--json" ]] && JSON=1

# shellcheck source=version-env.sh
source "$ROOT/scripts/version-env.sh"

LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [[ -z "$LAST_TAG" ]]; then
  LAST_TAG="(none)"
  UNSHIPPED="$(git log --oneline main 2>/dev/null | head -20 || true)"
else
  UNSHIPPED="$(git log --oneline "${LAST_TAG}..main" 2>/dev/null || true)"
fi

UNCOMMITTED="$(git status --porcelain 2>/dev/null || true)"
DIRTY_COUNT=0
if [[ -n "$UNCOMMITTED" ]]; then
  DIRTY_COUNT="$(printf '%s\n' "$UNCOMMITTED" | wc -l | tr -d ' ')"
fi

# Next patch per AGENTS.md roll rule (.9 → next minor).
next_version() {
  local v="$1"
  local major minor patch
  IFS=. read -r major minor patch <<<"$v"
  patch=$((patch + 1))
  if (( patch > 9 )); then
    minor=$((minor + 1))
    patch=0
  fi
  echo "${major}.${minor}.${patch}"
}
NEXT="$(next_version "$HEADROOM_VERSION")"

AHEAD="$(git rev-list --count "@{u}..HEAD" 2>/dev/null || echo 0)"
BEHIND="$(git rev-list --count "HEAD..@{u}" 2>/dev/null || echo 0)"

if [[ "$JSON" -eq 1 ]]; then
  python3 - <<PY
import json, subprocess, os
root = os.environ.get("ROOT", "$ROOT")
unshipped = """$UNSHIPPED""".strip().splitlines()
unshipped = [l for l in unshipped if l]
dirty = """$UNCOMMITTED""".strip().splitlines()
dirty = [l for l in dirty if l]
print(json.dumps({
  "version_file": "$HEADROOM_VERSION",
  "last_tag": "$LAST_TAG",
  "next_version": "$NEXT",
  "unshipped_commits": unshipped,
  "dirty_files": dirty,
  "ahead_of_origin": int("$AHEAD"),
  "behind_origin": int("$BEHIND"),
}, indent=2))
PY
  exit 0
fi

echo "=== Headroom ship inventory ==="
echo
echo "host/VERSION:     $HEADROOM_VERSION"
echo "Last tag:         $LAST_TAG"
echo "Next patch:       $NEXT  (if bumping now; recompute after each release)"
echo "Branch vs origin: +${AHEAD} unpushed / -${BEHIND} behind"
echo

if [[ -n "$UNSHIPPED" ]]; then
  echo "Unshipped on main since ${LAST_TAG}:"
  printf '%s\n' "$UNSHIPPED" | sed 's/^/  /'
else
  echo "Unshipped on main since ${LAST_TAG}: (none)"
fi
echo

if [[ "$DIRTY_COUNT" -gt 0 ]]; then
  echo "Dirty working tree (${DIRTY_COUNT} paths) — stage explicit paths per set; never git add -a:"
  printf '%s\n' "$UNCOMMITTED" | sed 's/^/  /'
else
  echo "Working tree: clean"
fi
echo

if command -v gh >/dev/null 2>&1; then
  echo "Recent Release workflow runs:"
  gh run list --workflow=release.yml --limit 3 2>/dev/null | sed 's/^/  /' || true
  echo
fi

echo "Suggested loop: ./scripts/ship-inventory.sh → partition → verify in worktree →"
echo "  CHANGELOG + chore: bump → push main → gh run watch (macOS job green before next bump)."
