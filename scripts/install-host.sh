#!/usr/bin/env bash
# Install the Headroom host as a login item (LaunchAgent) and start it.
#
# Usage (from anywhere):
#   ./scripts/install-host.sh
#   ./scripts/install-host.sh --foreground   # run once in this terminal instead
#
# Safe to re-run. Does not overwrite an existing ~/.headroom/config.json.
set -euo pipefail

FOREGROUND=0
PORT=8737
APP_PATH=""
die() { echo "error: $*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --foreground|-f) FOREGROUND=1 ;;
    --port=*) PORT="${arg#--port=}" ;;
    --app=*) APP_PATH="${arg#--app=}" ;;
    -h|--help)
      cat <<'EOF'
Install the Headroom host as a login item and start it.

  ./scripts/install-host.sh                 # from a git clone
  ./scripts/install-host.sh --foreground    # run once in this terminal
  ./scripts/install-host.sh --app=Headroom.app
  ./scripts/install-host.sh --port=8737

Prefer opening a Release Headroom.app and tapping “Start host” — that
installs the same LaunchAgent using the host bundled inside the app.

Safe to re-run. Keeps an existing ~/.headroom/config.json.
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "$APP_PATH" ]]; then
  APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
  HOST_DIR=""
  for cand in \
    "$APP_PATH/Contents/Resources/host" \
    "$APP_PATH/Contents/Resources/EmbeddedHost/host" \
    "$APP_PATH/Contents/Resources/EmbeddedHost"
  do
    if [[ -f "$cand/headroom_server.py" ]]; then
      HOST_DIR="$cand"
      break
    fi
  done
  [[ -n "$HOST_DIR" ]] || die "no bundled host inside $APP_PATH"
else
  HOST_DIR="$ROOT/host"
fi
SERVER="$HOST_DIR/headroom_server.py"
HOME_DIR="${HOME:?}"
HEADROOM_DIR="$HOME_DIR/.headroom"
LOG_DIR="$HEADROOM_DIR/logs"
CONFIG="$HEADROOM_DIR/config.json"
EXAMPLE="$HOST_DIR/config.example.json"
LABEL="com.centaur-labs.headroom"
PLIST_SRC="$ROOT/host/com.centaur-labs.headroom.plist"
[[ -f "$PLIST_SRC" ]] || PLIST_SRC="$HOST_DIR/com.centaur-labs.headroom.plist"
PLIST_DST="$HOME_DIR/Library/LaunchAgents/${LABEL}.plist"
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"

command -v python3 >/dev/null || die "python3 not found (macOS / Xcode CLT usually provides it)"
[[ -f "$SERVER" ]] || die "missing $SERVER — run this from a Headroom clone or pass --app="
python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' \
  || die "Python 3.9+ required (found $(python3 -V 2>&1))"

mkdir -p "$LOG_DIR" "$HOME_DIR/Library/LaunchAgents"

if [[ ! -f "$CONFIG" ]]; then
  if [[ -f "$EXAMPLE" ]]; then
    cp "$EXAMPLE" "$CONFIG"
    TZ_NAME="$(python3 - <<'PY' 2>/dev/null || true
import subprocess
try:
    out = subprocess.check_output(
        ["readlink", "/etc/localtime"], text=True, stderr=subprocess.DEVNULL
    ).strip()
except Exception:
    raise SystemExit
marker = "/zoneinfo/"
if marker in out:
    print(out.split(marker, 1)[1])
PY
)"
    if [[ -n "${TZ_NAME:-}" && "$TZ_NAME" == */* ]]; then
      python3 - "$CONFIG" "$TZ_NAME" <<'PY'
import json, sys
path, tz = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
data["timezone"] = tz
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
    fi
    echo "Wrote $CONFIG — edit git_authors / github_org_prefix / timezone for your machine."
  else
    echo '{}' >"$CONFIG"
    echo "Wrote empty $CONFIG (defaults apply)."
  fi
else
  echo "Keeping existing $CONFIG"
fi

PYTHON_BIN="$(command -v python3)"
# Prefer the real binary over a shim when available.
if [[ -x /usr/bin/python3 ]]; then
  PYTHON_BIN=/usr/bin/python3
fi

if [[ "$FOREGROUND" -eq 1 ]]; then
  echo "Starting host in the foreground on :$PORT (Ctrl-C to stop)…"
  echo "  $PYTHON_BIN $SERVER --port $PORT"
  cd "$HOST_DIR"
  exec "$PYTHON_BIN" "$SERVER" --port "$PORT"
fi

# Fill the template plist with this host dir + home.
# Template uses REPLACE_WITH_CLONE/host/… — map that onto HOST_DIR.
tmp="$(mktemp)"
HOST_PARENT="$(dirname "$HOST_DIR")"
sed \
  -e "s|REPLACE_WITH_CLONE/host|$HOST_DIR|g" \
  -e "s|REPLACE_WITH_CLONE|$HOST_PARENT|g" \
  -e "s|REPLACE_WITH_HOME|$HOME_DIR|g" \
  -e "s|/usr/bin/python3|$PYTHON_BIN|g" \
  -e "s|<string>8737</string>|<string>${PORT}</string>|g" \
  "$PLIST_SRC" >"$tmp"
mv "$tmp" "$PLIST_DST"
chmod 644 "$PLIST_DST"
echo "Installed $PLIST_DST (host=$HOST_DIR)"

# Replace any previous job. Also retire the pre-rename label so two KeepAlive
# agents cannot fight over :8737 (crash-loop / Address already in use).
LEGACY_LABEL="com.mz.headroom"
LEGACY_PLIST="$HOME_DIR/Library/LaunchAgents/${LEGACY_LABEL}.plist"
if launchctl print "$DOMAIN/$LEGACY_LABEL" >/dev/null 2>&1; then
  launchctl bootout "$DOMAIN/$LEGACY_LABEL" >/dev/null 2>&1 || true
fi
rm -f "$LEGACY_PLIST"
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
fi
launchctl bootstrap "$DOMAIN" "$PLIST_DST"
launchctl enable "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
launchctl kickstart -k "$DOMAIN/$LABEL"

echo -n "Waiting for http://127.0.0.1:${PORT}/health "
ok=0
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    ok=1
    break
  fi
  echo -n "."
  sleep 0.4
done
echo

if [[ "$ok" -eq 1 ]]; then
  echo "Host is up → http://127.0.0.1:${PORT}/usage"
else
  echo "Host did not respond yet. Check logs:" >&2
  echo "  tail -n 50 $LOG_DIR/headroom.err" >&2
  echo "  tail -n 50 $LOG_DIR/headroom.log" >&2
  exit 1
fi

cat <<EOF

Next:
  1. Build the menu bar app (once):
       cd $ROOT/macos && xcodegen generate
       xcodebuild -project Headroom.xcodeproj -scheme Headroom \\
         -configuration Debug -derivedDataPath .build build
       open .build/Build/Products/Debug/Headroom.app

  2. Open the popover → gear → Sources — enable only the providers you use
     (Claude / Codex / Cursor). Sign-in stays in those apps; Headroom just reads
     local credentials.

  3. Optional: edit $CONFIG for git authors, GitHub org, timezone.

Useful:
  launchctl kickstart -k $DOMAIN/$LABEL   # restart host
  ./scripts/uninstall-host.sh             # stop + remove LaunchAgent
  tail -f $LOG_DIR/headroom.log

EOF
