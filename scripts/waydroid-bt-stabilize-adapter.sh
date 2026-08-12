#!/bin/sh
# Stabilize com.android.bluetooth AdapterService bind on Waydroid (A13).
#
# Applies:
#   1) timerfd CLOCK_BOOTTIME_ALARM -> CLOCK_BOOTTIME patch on overlay JNI
#   2) ro.bluetooth.ble_start_timeout_delay=86400000 via overlay system/build.prop
#      (keeps BMS IBluetooth bound while stock Fluoride waits for missing HCI HAL)
#
# Prerequisites:
#   - Bluetooth.apk already restored into apex overlay (waydroid-restore-bluetooth-apk.sh)
#   - matching libbluetooth_jni.so in the same apex lib64 (or image default)
#   - run as root on the postmarketOS host that runs Waydroid
#
# After running: restart waydroid session, then:
#   sudo waydroid shell dumpsys bluetooth_manager
# Expect: no "Bluetooth Service not connected", AdapterProperties present.
set -eu

OVERLAY="${WAYDROID_OVERLAY:-/var/lib/waydroid/overlay}"
APEX_LIB="$OVERLAY/system/apex/com.android.btservices/lib64/libbluetooth_jni.so"
IMG="${WAYDROID_SYSTEM_IMG:-/var/lib/waydroid/images/system.img}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PATCH_PY="$SCRIPT_DIR/waydroid-patch-bt-jni-timerfd.py"

if [ "$(id -u)" -ne 0 ]; then
	echo "run as root" >&2
	exit 1
fi
if [ ! -f "$PATCH_PY" ]; then
	echo "missing $PATCH_PY" >&2
	exit 1
fi

# --- 1) timerfd patch ---
if [ ! -f "$APEX_LIB" ]; then
	echo "overlay JNI missing at $APEX_LIB — copy libbluetooth_jni.so first" >&2
	exit 1
fi
tmp=$(mktemp)
python3 "$PATCH_PY" "$APEX_LIB" "$tmp"
install -m644 "$tmp" "$APEX_LIB"
rm -f "$tmp"
echo "JNI_PATCHED $APEX_LIB"

# --- 2) BLE start timeout prop via full build.prop overlay ---
mkdir -p "$OVERLAY/system"
bp="$OVERLAY/system/build.prop"
if [ ! -f "$bp" ]; then
	mnt=$(mktemp -d)
	mount -o ro,loop "$IMG" "$mnt"
	cp "$mnt/system/build.prop" "$bp"
	umount "$mnt"
	rmdir "$mnt"
	echo "BUILD_PROP_SEEDED from $IMG"
fi
# idempotent append
if ! grep -q '^ro.bluetooth.ble_start_timeout_delay=' "$bp"; then
	printf '\n# waydroid-bt: keep AdapterService bound without HCI HAL\n' >>"$bp"
	echo 'ro.bluetooth.ble_start_timeout_delay=86400000' >>"$bp"
	echo 'ro.bluetooth.ble_stop_timeout_delay=86400000' >>"$bp"
	echo "BUILD_PROP_TIMEOUT_ADDED"
else
	echo "BUILD_PROP_TIMEOUT_PRESENT"
fi

echo "STABILIZE_OK"
echo "Restart Waydroid session for changes to apply."
