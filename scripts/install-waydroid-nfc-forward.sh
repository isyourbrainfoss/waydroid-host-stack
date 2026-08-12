#!/bin/sh
# Install waydroid-nfc-forward for zero-touch use on a Linux phone (pmOS/Phosh).
#
# Options:
#   --with-host-stack   apk add neard + libnfc-tools and try to start neard
set -eu

WITH_HOST_STACK=0
for arg in "$@"; do
  case "$arg" in
    --with-host-stack) WITH_HOST_STACK=1 ;;
    -h|--help)
      echo "Usage: $0 [--with-host-stack]"
      exit 0
      ;;
  esac
done

REPO_SCRIPT="$(CDPATH= cd -- "$(dirname "$0")" && pwd)/waydroid-nfc-forward.sh"
DEST="${HOME}/.local/bin/waydroid-nfc-forward"
HOOK_DEST="${HOME}/.local/bin/waydroid-nfc-session-hook"
START_UI="${HOME}/.local/bin/waydroid-start-ui"
GPS_HOOK="${HOME}/.local/bin/waydroid-gps-session-hook"
AUTOSTART_DIR="${HOME}/.config/autostart"

mkdir -p "${HOME}/.local/bin" "$AUTOSTART_DIR"

install -m 0755 "$REPO_SCRIPT" "$DEST"

# Session hook: arm NFC forward after Waydroid session start (idempotent).
cat >"$HOOK_DEST" <<'EOF'
#!/bin/sh
# Arm host→Waydroid NFC forward after session start (idempotent).
set -eu
export PATH="${HOME}/.local/bin:/usr/bin:/bin:${PATH:-}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
if [ ! -e /run/xdg/wayland-0 ] && [ -S "$XDG_RUNTIME_DIR/wayland-0" ]; then
  sudo -n mkdir -p /run/xdg 2>/dev/null || true
  sudo -n mount --bind "$XDG_RUNTIME_DIR" /run/xdg 2>/dev/null || true
fi
if command -v waydroid-nfc-forward >/dev/null 2>&1; then
  waydroid-nfc-forward enable >/dev/null 2>&1 || waydroid-nfc-forward start >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 0755 "$HOOK_DEST"

# Autostart at graphical login
cat >"$AUTOSTART_DIR/waydroid-nfc-forward.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Waydroid NFC Forward
Comment=Auto host NFC → Waydroid (zero-touch)
Exec=${HOME}/.local/bin/waydroid-nfc-forward enable
X-GNOME-Autostart-enabled=true
Hidden=false
NoDisplay=true
EOF

# Wire into waydroid-start-ui if present
if [ -f "$START_UI" ]; then
  if ! grep -q waydroid-nfc-session-hook "$START_UI" 2>/dev/null; then
    tmp="$START_UI.tmp.$$"
    if grep -q 'waydroid-gps-session-hook' "$START_UI" 2>/dev/null; then
      awk '
        { print }
        /waydroid-gps-session-hook/ && !done {
          print "waydroid-nfc-session-hook 2>/dev/null || true"
          done=1
        }
      ' "$START_UI" >"$tmp"
    else
      awk '
        /^exec waydroid show-full-ui/ && !done {
          print "waydroid-nfc-session-hook 2>/dev/null || true"
          done=1
        }
        { print }
      ' "$START_UI" >"$tmp"
    fi
    if grep -q waydroid-nfc-session-hook "$tmp" 2>/dev/null; then
      mv "$tmp" "$START_UI"
      chmod 0755 "$START_UI"
    else
      rm -f "$tmp"
    fi
  fi
fi

# If GPS session hook exists, append NFC arm so one hook arms both
if [ -f "$GPS_HOOK" ] && ! grep -q waydroid-nfc-forward "$GPS_HOOK" 2>/dev/null; then
  cat >>"$GPS_HOOK" <<'EOF'

# NFC forward (appended by install-waydroid-nfc-forward)
if command -v waydroid-nfc-forward >/dev/null 2>&1; then
  waydroid-nfc-forward enable >/dev/null 2>&1 || waydroid-nfc-forward start >/dev/null 2>&1 || true
fi
EOF
fi

export PATH="${HOME}/.local/bin:${PATH}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
"$DEST" enable

if [ "$WITH_HOST_STACK" = "1" ]; then
  "$DEST" install-host-stack || echo "host stack install skipped/failed (live field optional)"
fi

echo "Installed $DEST"
echo "Autostart: $AUTOSTART_DIR/waydroid-nfc-forward.desktop"
echo "Session hook: $HOOK_DEST"
echo "Live field: $DEST install-host-stack   # optional neard+libnfc-tools"
"$DEST" status || true
