#!/usr/bin/env bash
# Host-side smoke: build, dry-run daemon, optional live BlueZ probe.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== cargo test =="
cargo test --workspace

echo "== build release =="
cargo build --release -p waydroid-bt-host

SOCK="${WAYDROID_BT_SOCKET:-/tmp/waydroid-bt-smoke.sock}"
rm -f "$SOCK"

echo "== dry-run daemon =="
./target/release/waydroid-bt-host --dry-run --socket "$SOCK" &
PID=$!
cleanup() { kill "$PID" 2>/dev/null || true; rm -f "$SOCK"; }
trap cleanup EXIT
sleep 0.3

echo "== protocol Ping =="
./target/release/waydroid-bt-ping --socket "$SOCK" --client-name smoke-host

# Connectivity via guest C client (connect only)
if command -v gcc >/dev/null; then
  gcc -O2 -o /tmp/waydroid_bt_client "$ROOT/guest/hal/waydroid_bt_client.c"
  /tmp/waydroid_bt_client "$SOCK"
else
  echo "gcc not found; skipping C client connect test"
fi

echo "== host smoke OK =="

if command -v bluetoothctl >/dev/null; then
  echo "== bluetoothctl show (informational) =="
  bluetoothctl show || true
else
  echo "bluetoothctl not installed; skip live BlueZ info"
fi
