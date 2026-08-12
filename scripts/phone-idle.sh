#!/bin/sh
# Idle / overnight posture: stop high-drain field logging; optionally stop Waydroid.
# Leaves GPS/NFC user units armed (cheap skips when guest is down).
#
# Usage:
#   phone-idle                 # stop bt-log-session; stop Waydroid session if running
#   phone-idle --keep-waydroid # only stop field logs
#   phone-idle --dry-run
set -eu

DRY=0
KEEP_WD=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --keep-waydroid) KEEP_WD=1 ;;
    -h|--help)
      echo "Usage: phone-idle [--keep-waydroid] [--dry-run]"
      exit 0
      ;;
  esac
done

export PATH="${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

run() {
  if [ "$DRY" = "1" ]; then
    echo "DRY: $*"
  else
    "$@"
  fi
}

echo "=== phone-idle ==="

# Always target BT field log session stop
if command -v bt-log-session >/dev/null 2>&1; then
  if bt-log-session status 2>/dev/null | head -1 | grep -qiE 'running|active'; then
    run bt-log-session stop || true
  else
    # stop is idempotent for our script; still call to clear units
    run bt-log-session stop 2>/dev/null || echo "bt-log-session: already stopped"
  fi
else
  echo "bt-log-session: not installed (nothing to stop)"
fi

if [ "$KEEP_WD" = "1" ]; then
  echo "waydroid: kept (--keep-waydroid)"
else
  if command -v waydroid >/dev/null 2>&1; then
    st=$(waydroid status 2>/dev/null | sed -n 's/^Session:[[:space:]]*//p' | tr -d '[:space:]' || true)
    case "$st" in
      RUNNING*)
        run waydroid session stop || true
        ;;
      *)
        echo "waydroid: session already not RUNNING ($st)"
        ;;
    esac
  else
    echo "waydroid: not installed"
  fi
fi

echo "GPS/NFC forwarders left armed (rate-limited skips when guest down)."
echo "PHONE_IDLE_OK"
