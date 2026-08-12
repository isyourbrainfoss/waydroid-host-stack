#!/bin/sh
# Arm host→Waydroid GPS inject after session start (idempotent, zero-touch).
set -eu
export PATH="${HOME}/.local/bin:/usr/bin:/bin:${PATH:-}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

if [ ! -e /run/xdg/wayland-0 ] && [ -S "${XDG_RUNTIME_DIR}/wayland-0" ]; then
  sudo -n mkdir -p /run/xdg 2>/dev/null || true
  sudo -n mount --bind "$XDG_RUNTIME_DIR" /run/xdg 2>/dev/null || true
fi

if command -v waydroid-gps-forward >/dev/null 2>&1; then
  waydroid-gps-forward enable >/dev/null 2>&1 || waydroid-gps-forward start >/dev/null 2>&1 || true
fi
exit 0
