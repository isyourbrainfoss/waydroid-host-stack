#!/bin/sh
# Grant com.android.bluetooth the Android 12+ runtime "Nearby devices"
# permissions. The restored Lineage 20 Bluetooth.apk is not signed with the
# Waydroid image's platform key, so PackageManager does not pre-grant them;
# without BLUETOOTH_CONNECT every ProfileService (GattService first) logs
# "Permission denied!" and the adapter sticks in BLE_TURNING_ON forever.
# Root; idempotent. Prints per-permission result and the final grant state.
set -u
# shellcheck source=lib/guest.sh
. "$(CDPATH='' cd -- "$(dirname "$0")" && pwd)/lib/guest.sh"
whs_container_thaw || { echo "BT_PERMS_FAILED container not running"; exit 1; }
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
' 60
