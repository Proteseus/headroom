#!/usr/bin/env bash
# Copy the stdlib host into macos/host for bundling inside HeadroomBar.app.
# The folder is named `host` in the app bundle (see macos/project.yml).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/host"
DST="$ROOT/macos/host"
rm -rf "$DST"
mkdir -p "$DST"
rsync -a \
  --include='*/' \
  --include='*.py' \
  --include='config.example.json' \
  --include='com.mz.headroom.plist' \
  --exclude='test_*.py' \
  --exclude='__pycache__/' \
  --exclude='*.pyc' \
  --exclude='.*' \
  "$SRC/" "$DST/"
find "$DST" -name 'test_*.py' -delete
# Drop empty leftover dirs and ensure headroom_server.py is present.
[[ -f "$DST/headroom_server.py" ]] || {
  echo "error: sync failed — headroom_server.py missing" >&2
  exit 1
}
echo "Synced host → $DST ($(find "$DST" -name '*.py' | wc -l | tr -d ' ') py files)"
