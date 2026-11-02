#!/bin/sh
# Grant com.android.bluetooth the Android 12+ runtime "Nearby devices"
# permissions. The restored Lineage 20 Bluetooth.apk is not signed with the
# Waydroid image's platform key, so PackageManager does not pre-grant them;
# without BLUETOOTH_CONNECT every ProfileService (GattService first) logs
# "Permission denied!" and the adapter sticks in BLE_TURNING_ON forever.
# Root; idempotent. Prints per-permission result and the final grant state.
#
# Granting does not reach the running Bluetooth process: one that booted
# without BLUETOOTH_CONNECT stays wedged in BLE_TURNING_ON ("GattService:
# Permission denied!", USER_TURN_ON/OFF unhandled). So after granting, this
# script restarts com.android.bluetooth (kill; BluetoothManagerService rebinds
# with the new grants) and re-enables Bluetooth. --no-restart skips that.
#
#   waydroid-bt-grant-perms.sh [--no-restart]
set -u
RESTART=1
case "${1:-}" in
--no-restart) RESTART=0 ;;
'') ;;
*) echo "usage: $0 [--no-restart]" >&2; exit 2 ;;
esac
# shellcheck source=lib/guest.sh
. "$(CDPATH='' cd -- "$(dirname "$0")" && pwd)/lib/guest.sh"
whs_container_thaw || { echo "BT_PERMS_FAILED container not running"; exit 1; }
out=$(mktemp)
gsh '
P=com.android.bluetooth
for perm in BLUETOOTH_CONNECT BLUETOOTH_SCAN BLUETOOTH_ADVERTISE \
            ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION ACCESS_BACKGROUND_LOCATION \
            POST_NOTIFICATIONS READ_CONTACTS READ_CALL_LOG READ_PHONE_STATE \
            READ_SMS RECEIVE_SMS SEND_SMS NEARBY_WIFI_DEVICES; do
  if pm grant $P android.permission.$perm 2>/tmp/whs_grant_err; then echo "granted $perm"
  else echo "skip $perm: $(head -c 120 /tmp/whs_grant_err)"; fi
done
pm set-permission-flags $P android.permission.BLUETOOTH_CONNECT system-fixed 2>/dev/null
appops set $P android:bluetooth_connect allow 2>/dev/null
appops set $P android:bluetooth_scan allow 2>/dev/null
appops set $P android:bluetooth_advertise allow 2>/dev/null
echo "--- state"
dumpsys package $P | grep -E "userId=|sharedUser|signatures|BLUETOOTH_(CONNECT|SCAN|ADVERTISE|PRIVILEGED).*granted" | head -12
dumpsys package $P | grep -q "BLUETOOTH_CONNECT: granted=true" && echo BT_PERMS_OK || echo BT_PERMS_FAILED
' 60 | tee "$out"
rc=1
grep -q BT_PERMS_OK "$out" && rc=0
rm -f "$out"
[ "$rc" -eq 0 ] || exit 1
[ "$RESTART" -eq 1 ] || exit 0

# Restart the Bluetooth app so it picks up the grants.
bt_pid() { gsh 'pidof com.android.bluetooth' 2>/dev/null | tr -d '\r\n'; }
old=$(bt_pid)
case "$old" in *[!0-9\ ]*) old="" ;; esac
echo "restarting com.android.bluetooth (pid ${old:-none}) to pick up grants"
if [ -n "$old" ]; then
	gsh "kill -9 $old" >/dev/null 2>&1 || true
fi
new=""
i=0
while [ "$i" -lt 30 ]; do
	new=$(bt_pid)
	[ -n "$new" ] && [ "$new" != "$old" ] && break
	i=$((i + 2))
	sleep 2
done
echo "com.android.bluetooth pid=${new:-none} after ${i}s"
gsh 'cmd bluetooth_manager enable' >/dev/null 2>&1 || true
[ -n "$new" ] && [ "$new" != "$old" ] && echo BT_RESTART_OK || echo "BT_RESTART_PENDING (BluetoothManagerService will rebind on next enable)"
exit 0
