#!/usr/bin/env bash
# Guest-side smoke (run on phone with Waydroid session up).
set -euo pipefail

echo "== waydroid status =="
waydroid status || true

echo "== host socket =="
ls -l /run/waydroid-bt/host.sock || {
  echo "FAIL: host socket missing (start waydroid-bt-host.service)"
  exit 1
}

echo "== guest socket via waydroid shell =="
waydroid shell ls -l /dev/socket/waydroid_bt || {
  echo "FAIL: guest socket missing (apply lxc mount, restart container)"
  exit 1
}

echo "== guest connect test =="
if waydroid shell test -x /system/bin/waydroid_bt_client 2>/dev/null; then
  waydroid shell /system/bin/waydroid_bt_client /dev/socket/waydroid_bt
else
  echo "waydroid_bt_client not installed in image; checking socket only"
  waydroid shell sh -c 'test -S /dev/socket/waydroid_bt && echo OK: socket exists'
fi

echo "== Bluetooth packages (expect present on custom image) =="
waydroid shell pm list packages 2>/dev/null | grep -i bluetooth || \
  echo "WARN: no bluetooth packages — custom image not installed yet"

echo "== guest smoke done =="
