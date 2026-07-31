#!/usr/bin/env bash
# Collect host + guest logs for bug reports.
set -euo pipefail
OUT="${1:-./waydroid-bt-logs-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"

{
  echo "date: $(date -Is)"
  echo "uname: $(uname -a)"
  command -v bluetoothctl >/dev/null && bluetoothctl --version || true
  cat /etc/os-release 2>/dev/null || true
} >"$OUT/host-meta.txt"

journalctl -u waydroid-bt-host -n 200 --no-pager >"$OUT/waydroid-bt-host.journal" 2>/dev/null || true
journalctl -u bluetooth -n 100 --no-pager >"$OUT/bluetooth.journal" 2>/dev/null || true
journalctl -u waydroid-container -n 100 --no-pager >"$OUT/waydroid-container.journal" 2>/dev/null || true

bluetoothctl show >"$OUT/bluetoothctl-show.txt" 2>/dev/null || true
ls -la /run/waydroid-bt/ >"$OUT/run-waydroid-bt.txt" 2>/dev/null || true

if command -v waydroid >/dev/null; then
  waydroid status >"$OUT/waydroid-status.txt" 2>/dev/null || true
  waydroid shell logcat -d -s BluetoothManagerService:V bluetooth:V 2>/dev/null \
    | tail -n 300 >"$OUT/guest-logcat-bt.txt" || true
fi

echo "logs written to $OUT"
