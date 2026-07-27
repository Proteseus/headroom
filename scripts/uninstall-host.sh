#!/usr/bin/env bash
# Stop the Headroom host LaunchAgent and remove its plist.
# Does not delete ~/.headroom (config, caches, token, logs) — pass --purge for that.
set -euo pipefail

PURGE=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    -h|--help)
      sed -n '2,5p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

LABEL="com.mz.headroom"
HOME_DIR="${HOME:?}"
PLIST_DST="$HOME_DIR/Library/LaunchAgents/${LABEL}.plist"
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "$DOMAIN/$LABEL" || true
  echo "Stopped $DOMAIN/$LABEL"
else
  echo "LaunchAgent not loaded ($DOMAIN/$LABEL)"
fi

if [[ -f "$PLIST_DST" ]]; then
  rm -f "$PLIST_DST"
  echo "Removed $PLIST_DST"
fi

if [[ "$PURGE" -eq 1 ]]; then
  rm -rf "$HOME_DIR/.headroom"
  echo "Removed $HOME_DIR/.headroom"
else
  echo "Left $HOME_DIR/.headroom in place (pass --purge to delete config/logs/token)."
fi
