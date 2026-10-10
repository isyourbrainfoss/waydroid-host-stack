#!/bin/sh
# Install the Soft IBluetoothHci HAL (HIDL 1.0) into the Waydroid overlay.
#
#   sudo waydroid-install-soft-hci-hal.sh HAL_BINARY [HAL_SRC_DIR]
#
# HAL_BINARY   android.hardware.bluetooth@1.0-service.waydroid (guest/hal/build_ndk.sh)
# HAL_SRC_DIR  guest/hal checkout (wrapper .sh, .rc, VINTF manifest); defaults
#              to $WAYDROID_BT_HAL_SRC or ../guest/hal next to this script.
#
# Installs (overlay, applied at next container start, mount_overlays=True):
#   system/bin/hw/android.hardware.bluetooth@1.0-service.waydroid
#   system/bin/bluetooth-hci-waydroid                        (single-instance launcher)
#   system/etc/init/android.hardware.bluetooth@1.0-service.waydroid.rc
#   vendor/etc/vintf/manifest/android.hardware.bluetooth@1.0-service.waydroid.xml
# Idempotent. Refuses on non-TQ3A images (lineage-guard).
set -eu

BIN="${1:-}"
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SRC="${2:-${WAYDROID_BT_HAL_SRC:-}}"
if [ -z "$SRC" ]; then
	for c in "$SCRIPT_DIR/../guest/hal" "$SCRIPT_DIR/guest-hal"; do
		[ -f "$c/android.hardware.bluetooth@1.0-service.waydroid.rc" ] && SRC=$c && break
	done
fi
OVERLAY="${WAYDROID_OVERLAY:-/var/lib/waydroid/overlay}"
LIBDIR="${WHS_LIBDIR:-$SCRIPT_DIR/lib}"

if [ "$(id -u)" -ne 0 ]; then
	echo "run as root" >&2
	exit 1
fi
if [ -z "$BIN" ] || [ ! -f "$BIN" ]; then
	echo "usage: $0 /path/to/android.hardware.bluetooth@1.0-service.waydroid [guest/hal dir]" >&2
	exit 1
fi
if [ -z "$SRC" ] || [ ! -f "$SRC/bluetooth-hci-waydroid.sh" ]; then
	echo "missing HAL source dir (bluetooth-hci-waydroid.sh / .rc / manifest): '$SRC'" >&2
	exit 1
fi
# ELF sanity: aarch64 Android executable (linker64)
if ! grep -q '/system/bin/linker64' "$BIN" 2>/dev/null; then
	echo "refusing: $BIN is not an Android aarch64 executable (no /system/bin/linker64 interp)" >&2
	exit 1
fi
if [ -f "$LIBDIR/lineage-guard.sh" ]; then
	# shellcheck source=scripts/lib/lineage-guard.sh
	. "$LIBDIR/lineage-guard.sh"
	whs_lineage_guard || { echo "HAL_INSTALL_REFUSED (version guard)" >&2; exit 1; }
fi

install -D -m 0755 "$BIN" "$OVERLAY/system/bin/hw/android.hardware.bluetooth@1.0-service.waydroid"
install -D -m 0755 "$SRC/bluetooth-hci-waydroid.sh" "$OVERLAY/system/bin/bluetooth-hci-waydroid"
install -D -m 0644 "$SRC/android.hardware.bluetooth@1.0-service.waydroid.rc" \
	"$OVERLAY/system/etc/init/android.hardware.bluetooth@1.0-service.waydroid.rc"
install -D -m 0644 "$SRC/manifest_android.hardware.bluetooth@1.0.xml" \
	"$OVERLAY/vendor/etc/vintf/manifest/android.hardware.bluetooth@1.0-service.waydroid.xml"

echo "HAL_INSTALL_OK overlay=$OVERLAY"
ls -la "$OVERLAY/system/bin/hw/android.hardware.bluetooth@1.0-service.waydroid" \
	"$OVERLAY/system/bin/bluetooth-hci-waydroid" \
	"$OVERLAY/system/etc/init/android.hardware.bluetooth@1.0-service.waydroid.rc" \
	"$OVERLAY/vendor/etc/vintf/manifest/android.hardware.bluetooth@1.0-service.waydroid.xml"
