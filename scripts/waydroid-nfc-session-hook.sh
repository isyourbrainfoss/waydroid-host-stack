#!/bin/sh
# Arm host→Waydroid NFC forward after session start (idempotent).
set -eu
export PATH="${HOME}/.local/bin:/usr/bin:/bin:${PATH:-}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
# /run/xdg is bound by the root unit waydroid-run-xdg.path/.service
# (installed by install-host-system.sh). No sudo from user hooks.
if [ ! -e /run/xdg/wayland-0 ] && [ -S "$XDG_RUNTIME_DIR/wayland-0" ]; then
  systemctl start --no-ask-password waydroid-run-xdg.service 2>/dev/null || true
fi
if command -v waydroid-nfc-forward >/dev/null 2>&1; then
  waydroid-nfc-forward enable >/dev/null 2>&1 || waydroid-nfc-forward start >/dev/null 2>&1 || true
fi
exit 0
