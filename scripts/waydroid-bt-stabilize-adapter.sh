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
#   - run as root on the host that runs Waydroid
#   - image must be Lineage 20 / Android 13 (SDK 33, TQ3A) — enforced by
#     scripts/lib/lineage-guard.sh (override: WAYDROID_BT_SKIP_VERSION_GUARD=1)
#
# After running: restart waydroid session, then:
#   sudo waydroid shell dumpsys bluetooth_manager
# Expect: no "Bluetooth Service not connected", AdapterProperties present.
set -eu

OVERLAY="${WAYDROID_OVERLAY:-/var/lib/waydroid/overlay}"
APEX_LIB="$OVERLAY/system/apex/com.android.btservices/lib64/libbluetooth_jni.so"
IMG="${WAYDROID_SYSTEM_IMG:-/var/lib/waydroid/images/system.img}"
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PATCH_PY="$SCRIPT_DIR/waydroid-patch-bt-jni-timerfd.py"
# Prefer the std-only Rust patcher (no python3 on image-based hosts).
LIBDIR="${WHS_LIBDIR:-$SCRIPT_DIR/lib}"
[ -d "$LIBDIR" ] || LIBDIR="${PREFIX:-/var/lib/waydroid-host-stack}/lib"
# shellcheck source=scripts/lib/paths.sh
. "$LIBDIR/paths.sh"
# shellcheck source=scripts/lib/lineage-guard.sh
. "$LIBDIR/lineage-guard.sh"
whs_resolve_paths
PATCH_BIN="${WAYDROID_BT_JNI_PATCH:-}"
if [ -z "$PATCH_BIN" ]; then
	PATCH_BIN=$(command -v waydroid-bt-jni-patch 2>/dev/null || whs_find_helper waydroid-bt-jni-patch || true)
fi

if [ "$(id -u)" -ne 0 ]; then
	echo "run as root" >&2
	exit 1
fi
if [ -z "$PATCH_BIN" ] && { [ ! -f "$PATCH_PY" ] || ! command -v python3 >/dev/null 2>&1; }; then
	echo "missing patcher: install waydroid-bt-jni-patch (cargo build -p waydroid-bt-host) or python3 + $PATCH_PY" >&2
	exit 1
fi

# Offsets/props are only valid for Lineage 20 / Android 13 (SDK 33, TQ3A).
if ! whs_lineage_guard; then
	echo "STABILIZE_REFUSED (version guard)" >&2
	exit 1
fi

# --- 1) timerfd patch ---
if [ ! -f "$APEX_LIB" ]; then
	echo "overlay JNI missing at $APEX_LIB — copy libbluetooth_jni.so first" >&2
	exit 1
fi
tmp=$(mktemp)
if [ -n "$PATCH_BIN" ]; then
	"$PATCH_BIN" "$APEX_LIB" "$tmp"
else
	python3 "$PATCH_PY" "$APEX_LIB" "$tmp"
fi
install -m644 "$tmp" "$APEX_LIB"
rm -f "$tmp"
echo "JNI_PATCHED $APEX_LIB"

# --- 2) BLE start timeout prop via full build.prop overlay ---
mkdir -p "$OVERLAY/system"
bp="$OVERLAY/system/build.prop"
if [ ! -f "$bp" ]; then
	WAYDROID_SYSTEM_IMG="$IMG" whs_read_build_prop >"$bp.tmp"
	if ! grep -q '^ro.build.version.sdk=' "$bp.tmp"; then
		rm -f "$bp.tmp"
		echo "could not read system/build.prop from $IMG" >&2
		exit 1
	fi
	mv "$bp.tmp" "$bp"
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
