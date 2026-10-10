#!/bin/sh
# Install waydroid-gps-forward for zero-touch use on a Linux phone (pmOS/Phosh).
set -eu

REPO_SCRIPT="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)/waydroid-gps-forward.sh"
DEST="${HOME}/.local/bin/waydroid-gps-forward"
DESKTOP_SRC="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)/waydroid-gps-forward.desktop"
DESKTOP_DEST="${HOME}/.local/share/applications/waydroid-gps-forward.desktop"
HOOK_DEST="${HOME}/.local/bin/waydroid-gps-session-hook"
START_UI="${HOME}/.local/bin/waydroid-start-ui"
AUTOSTART_DIR="${HOME}/.config/autostart"

mkdir -p "${HOME}/.local/bin" "${HOME}/.local/share/applications" "$AUTOSTART_DIR"

install -m 0755 "$REPO_SCRIPT" "$DEST"
if [ -f "$DESKTOP_SRC" ]; then
  install -m 0644 "$DESKTOP_SRC" "$DESKTOP_DEST"
fi

# Session hook: arm GPS forward whenever something calls it after session start
cat >"$HOOK_DEST" <<'EOF'
#!/bin/sh
# Arm host→Waydroid GPS inject after session start (idempotent).
set -eu
export PATH="${HOME}/.local/bin:/usr/bin:/bin:${PATH:-}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
# /run/xdg for Waydroid session props
# /run/xdg is bound by the root unit waydroid-run-xdg.path/.service
# (installed by install-host-system.sh). No sudo from user hooks.
if [ ! -e /run/xdg/wayland-0 ] && [ -S "$XDG_RUNTIME_DIR/wayland-0" ]; then
  systemctl start --no-ask-password waydroid-run-xdg.service 2>/dev/null || true
fi
if command -v waydroid-gps-forward >/dev/null 2>&1; then
  waydroid-gps-forward enable >/dev/null 2>&1 || waydroid-gps-forward start >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 0755 "$HOOK_DEST"

# Autostart at graphical login (arms loop; inject waits for Waydroid boot)
cat >"$AUTOSTART_DIR/waydroid-gps-forward.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Waydroid GPS Forward
Comment=Auto host GPS → Waydroid (zero-touch)
Exec=${HOME}/.local/bin/waydroid-gps-forward enable
X-GNOME-Autostart-enabled=true
Hidden=false
NoDisplay=true
EOF

# Wire into waydroid-start-ui if present
if [ -f "$START_UI" ]; then
  if ! grep -q waydroid-gps-forward "$START_UI" 2>/dev/null; then
    # Insert arm call before show-full-ui
    tmp="$START_UI.tmp.$$"
    # shellcheck disable=SC2016
    sed 's|^exec waydroid show-full-ui|waydroid-gps-session-hook 2>/dev/null || true\nexec waydroid show-full-ui|' \
      "$START_UI" >"$tmp" 2>/dev/null || cp "$START_UI" "$tmp"
    if ! grep -q waydroid-gps-session-hook "$tmp" 2>/dev/null; then
      # fallback append before last line
      {
        head -n -1 "$START_UI" 2>/dev/null || sed '$d' "$START_UI"
        echo 'waydroid-gps-session-hook 2>/dev/null || true'
        echo 'exec waydroid show-full-ui'
      } >"$tmp"
    fi
    mv "$tmp" "$START_UI"
    chmod 0755 "$START_UI"
  fi
fi

export PATH="${HOME}/.local/bin:${PATH}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
"$DEST" enable

echo "Installed $DEST"
echo "Autostart: $AUTOSTART_DIR/waydroid-gps-forward.desktop"
echo "Session hook: $HOOK_DEST"
"$DEST" status || true
