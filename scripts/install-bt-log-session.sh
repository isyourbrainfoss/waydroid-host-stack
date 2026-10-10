#!/bin/sh
# Install BT Log Session launcher into Phosh app drawer (user-local).
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
BIN_DIR="${HOME}/.local/bin"
APP_DIR="${HOME}/.local/share/applications"

mkdir -p "$BIN_DIR" "$APP_DIR"
install -m 0755 "$ROOT/scripts/bt-log-session.sh" "$BIN_DIR/bt-log-session"
# Desktop file with absolute Exec for environments that skip ~/.local/bin
sed "s|^Exec=.*|Exec=$BIN_DIR/bt-log-session toggle|" \
  "$ROOT/scripts/bt-log-session.desktop" >"$APP_DIR/bt-log-session.desktop"
chmod 0644 "$APP_DIR/bt-log-session.desktop"

# Refresh desktop database if available
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APP_DIR" 2>/dev/null || true
fi

echo "Installed:"
echo "  $BIN_DIR/bt-log-session"
echo "  $APP_DIR/bt-log-session.desktop"
echo ""
echo "In Phosh: open app drawer, search \"BT Log\"."
echo "Tap once = start logging near the car."
echo "Tap again = stop and finalize ~/bt-log-sessions/session-*/"
echo ""
echo "Optional verbose HCI capture:"
echo "  BT_LOG_BTMON=1 $BIN_DIR/bt-log-session start"
