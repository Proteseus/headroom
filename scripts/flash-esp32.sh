#!/usr/bin/env bash
# Flash the ESP32 board, but refuse if anything else owns the serial port.
#
# The port takes exactly one owner. Headroom.app's host server keeps it open to
# push /usage over USB-CDC, so a flash launched while the app is running fights
# it for the port. esptool does not fail cleanly when that happens: it can get
# partway through writing the app partition and then stop responding, which
# leaves the board unbootable and needing a manual BOOT+RESET to recover.
#
# So: check first, stop if busy, never race.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIO="${PIO:-$(command -v pio || echo "$HOME/.platformio/penv/bin/pio")}"
PIO_ENV="${HEADROOM_PIO_ENV:-esp32-s3-18}"

if [[ ${1:-} == "-e" || ${1:-} == "--environment" ]]; then
  [[ $# -ge 2 ]] || { echo "error: $1 needs an environment" >&2; exit 2; }
  PIO_ENV="$2"
  shift 2
fi

case "$PIO_ENV" in
  esp32-s3-18|esp32-s3-216|esp32-s3-175-round) ;;
  *)
    echo "error: unsupported Headroom environment: $PIO_ENV" >&2
    exit 2
    ;;
esac

if [[ ! -x "$PIO" ]]; then
  echo "error: pio not found. Set PIO=/path/to/pio" >&2
  exit 1
fi

ports=(/dev/cu.usbmodem* /dev/tty.usbmodem*)
found=0
busy=0

for port in "${ports[@]}"; do
  [[ -e "$port" ]] || continue
  found=1
  holder="$(lsof -t "$port" 2>/dev/null || true)"
  [[ -n "$holder" ]] || continue
  busy=1
  echo "error: $port is already open by:" >&2
  for pid in $holder; do
    echo "  pid $pid  $(ps -o command= -p "$pid" 2>/dev/null | cut -c1-100)" >&2
  done
done

if [[ $found -eq 0 ]]; then
  echo "error: no /dev/*.usbmodem* port. Is the board plugged in?" >&2
  exit 1
fi

if [[ $busy -ne 0 ]]; then
  cat >&2 <<EOF

Stopping rather than racing for the port. Usually this is the host server,
which runs from a KeepAlive LaunchAgent — quitting Headroom.app does not
release it, and killing it just makes launchd respawn it seconds later.

Stop the agent, flash, then always put it back:

  launchctl bootout gui/$(id -u)/com.centaur-labs.headroom
  $0
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.centaur-labs.headroom.plist

The board gets its usage data from that process. Leaving it unloaded looks
exactly like a broken board on the next boot.
EOF
  exit 1
fi

cd "$ROOT/firmware"
exec "$PIO" run -e "$PIO_ENV" -t upload "$@"
