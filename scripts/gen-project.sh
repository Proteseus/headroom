#!/usr/bin/env bash
# Generate macos/Headroom.xcodeproj from macos/project.yml.
#
#   ./scripts/gen-project.sh
#
# Always go through this rather than calling `xcodegen generate` directly.
# project.yml lists macos/host as a source directory, but that folder is a copy
# of the stdlib host made by sync-embedded-host.sh and is gitignored. On a fresh
# clone bare xcodegen fails with:
#
#   Spec validation error: Target "Headroom" has a missing source directory
#   ".../macos/host"
#
# followed by `xcodebuild: error: 'Headroom.xcodeproj' does not exist.`, which
# does not point at the real cause. Syncing first makes that unreachable.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

command -v xcodegen >/dev/null || {
  echo "error: install xcodegen (brew install xcodegen)" >&2
  exit 1
}

"$ROOT/scripts/sync-embedded-host.sh"
cd "$ROOT/macos"
xcodegen generate
