#!/usr/bin/env bash
# Fail when a constant that exists in two languages stops agreeing.
#
# Several numbers are duplicated across the Python host, the Swift clients and
# the ESP32 firmware because there is no build step that could share them. Each
# copy is currently kept in step by a comment saying "mirrors X", which works
# right up until someone changes one side alone. The symptom is not a build
# error — it is the board drawing four rows into a five-row buffer, or the host
# trimming a list the firmware still expects.
#
# This is the stopgap. The real fix is generating all of them from one file
# (docs/contract.md); until that exists, this at least makes drift loud.
#
# Usage: ./scripts/check-mirrored-constants.sh

set -euo pipefail

cd "$(dirname "$0")/.."

FIRMWARE="firmware/src/main.cpp"
DEVICE_VIEW="host/device_view.py"
SOURCES="host/sources_config.py"

fail=0

note() {
  printf '  %s\n' "$1"
}

mismatch() {
  printf 'MISMATCH  %s\n' "$1"
  fail=1
}

# Pull `static const <type> NAME = <value>;` out of the firmware.
cpp_const() {
  sed -n "s/^static const [a-z0-9_]* $1 *= *\([0-9][0-9]*\).*/\1/p" \
    "$FIRMWARE" | head -1
}

# Pull `NAME = <value>` out of a Python module, ignoring indented assignments
# so a local variable cannot shadow the module constant.
py_const() {
  sed -n "s/^$1 *= *\([0-9][0-9]*\).*/\1/p" "$2" | head -1
}

compare() {
  local label="$1" left="$2" right="$3" left_where="$4" right_where="$5"
  if [ -z "$left" ]; then
    mismatch "$label: not found in $left_where"
    return
  fi
  if [ -z "$right" ]; then
    mismatch "$label: not found in $right_where"
    return
  fi
  if [ "$left" != "$right" ]; then
    mismatch "$label: $left_where says $left, $right_where says $right"
    return
  fi
  note "$label = $left"
}

echo "mirrored constants"

# Row caps: the host trims each list to what the firmware can store.
for name in MAX_DEPLOYS MAX_COMMITS MAX_SERVERS; do
  compare "$name" \
    "$(cpp_const "$name")" "$(py_const "$name" "$DEVICE_VIEW")" \
    "$FIRMWARE" "$DEVICE_VIEW"
done

# The board's three provider slots. Three names for one number, on purpose:
# the firmware stores slots, the projection caps rows, the registry picks which.
slots="$(cpp_const MAX_SLOTS)"
compare "MAX_SLOTS/MAX_PROVIDERS" \
  "$slots" "$(py_const MAX_PROVIDERS "$DEVICE_VIEW")" \
  "$FIRMWARE" "$DEVICE_VIEW"
compare "MAX_PROVIDERS/FOCUS_LIMIT" \
  "$(py_const MAX_PROVIDERS "$DEVICE_VIEW")" \
  "$(py_const FOCUS_LIMIT "$SOURCES")" \
  "$DEVICE_VIEW" "$SOURCES"

# Meters drawn per provider.
compare "MAX_POOLS" \
  "$(cpp_const MAX_POOLS)" "$(py_const MAX_POOLS "$DEVICE_VIEW")" \
  "$FIRMWARE" "$DEVICE_VIEW"

# Sources-page rows and the two glance histories. The firmware sizes fixed
# arrays from these; the host trims each list to match.
for name in MAX_SOURCES MAX_ACTIVITY_DAYS MAX_DAILY_BURN_DAYS; do
  compare "$name" \
    "$(cpp_const "$name")" "$(py_const "$name" "$DEVICE_VIEW")" \
    "$FIRMWARE" "$DEVICE_VIEW"
done

# Points per burndown curve in the device view.
compare "MAX_BURNDOWN_POINTS/MAX_BURN_PTS" \
  "$(cpp_const MAX_BURN_PTS)" \
  "$(py_const MAX_BURNDOWN_POINTS "$DEVICE_VIEW")" \
  "$FIRMWARE" "$DEVICE_VIEW"

# The spent-window curve behind a burndown, and the grant rules drawn on it.
# The firmware sizes fixed arrays from these; the host decides how many points
# to send. Host larger than firmware is a silently truncated curve.
compare "MAX_HISTORY_POINTS/MAX_HIST_PTS" \
  "$(cpp_const MAX_HIST_PTS)" \
  "$(py_const MAX_HISTORY_POINTS "$DEVICE_VIEW")" \
  "$FIRMWARE" "$DEVICE_VIEW"
compare "MAX_GRANT_MARKS/MAX_GRANTS" \
  "$(cpp_const MAX_GRANTS)" \
  "$(py_const MAX_GRANT_MARKS "$DEVICE_VIEW")" \
  "$FIRMWARE" "$DEVICE_VIEW"

if [ "$fail" -ne 0 ]; then
  echo
  echo "A mirrored constant drifted. Both sides have to move together —"
  echo "see docs/contract.md, 'Constants that live in more than one language'."
  exit 1
fi

echo "mirrored constants ok"
