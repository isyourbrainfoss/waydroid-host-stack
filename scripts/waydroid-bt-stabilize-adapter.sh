#!/bin/sh
# Stabilize com.android.bluetooth AdapterService bind on Waydroid (A13).
#
# Applies:
#   1) timerfd CLOCK_BOOTTIME_ALARM -> CLOCK_BOOTTIME patch on overlay JNI
#   2) ro.bluetooth.ble_start_timeout_delay=86400000 via overlay system/build.prop
#      (keeps BMS IBluetooth bound while stock Fluoride waits for missing HCI HAL)
#
# The overlay build.prop is a full copy of the image's (Waydroid overlays whole
# files, a partial build.prop would drop every other system prop). A copy left
# over from an older image would hide the new image's props after a Waydroid
# OTA, so the copy is tied to the image's build.prop: its sha256 and
# fingerprint are recorded in $WHS_STATE_DIR/build-prop.src, and whenever the
# image's build.prop changes the overlay copy is re-seeded from the new image
# (our props re-appended). If the new image no longer passes the version
# guard, the overlay copy is moved aside so the image's own build.prop applies.
# waydroid-container.service runs `--resync` before every start.
#
#   waydroid-bt-stabilize-adapter.sh                  JNI patch + build.prop
#   waydroid-bt-stabilize-adapter.sh --build-prop-only  seed/re-sync build.prop only
#   waydroid-bt-stabilize-adapter.sh --resync         like --build-prop-only, but only
#                                                     touches a copy this script manages
#   waydroid-bt-stabilize-adapter.sh --check          exit 1 if the copy is stale
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

MODE=full
case "${1:-}" in
--build-prop-only) MODE=prop ;;
--resync) MODE=resync ;;
--check) MODE=check ;;
'') ;;
*) echo "usage: $0 [--build-prop-only|--resync|--check]" >&2; exit 2 ;;
esac

OVERLAY="${WAYDROID_OVERLAY:-/var/lib/waydroid/overlay}"
APEX_LIB="$OVERLAY/system/apex/com.android.btservices/lib64/libbluetooth_jni.so"
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
# system.img: $WAYDROID_SYSTEM_IMG, else images_path from waydroid.cfg, else
# /var/lib/waydroid/images (lineage-guard.sh resolves it).
IMG="$WAYDROID_SYSTEM_IMG"
PATCH_BIN="${WAYDROID_BT_JNI_PATCH:-}"
if [ -z "$PATCH_BIN" ]; then
	PATCH_BIN=$(command -v waydroid-bt-jni-patch 2>/dev/null || whs_find_helper waydroid-bt-jni-patch || true)
fi

STATE_DIR="${WHS_STATE_DIR:-/var/lib/waydroid-host-stack/state}"
SRC_STAMP="$STATE_DIR/build-prop.src"
bp="$OVERLAY/system/build.prop"
OUR_PROPS='ro.bluetooth.ble_start_timeout_delay=86400000
ro.bluetooth.ble_stop_timeout_delay=86400000'

# image_props FILE -> write the image's build.prop to FILE; fail unless it is
# a real build.prop (not the 2-line `waydroid shell getprop` fallback).
image_props() {
	WAYDROID_SYSTEM_IMG="$IMG" whs_read_build_prop >"$1" 2>/dev/null || true
	grep -q '^ro.build.version.sdk=' "$1" && [ "$(wc -l <"$1")" -ge 20 ]
}

# stamp FILE -> "sha256 fingerprint" of an image build.prop.
stamp() {
	h=$(sha256sum "$1" | cut -d' ' -f1)
	fp=$(sed -n 's/^ro.system.build.fingerprint=//p' "$1" | head -n1)
	[ -n "$fp" ] || fp=$(sed -n 's/^ro.build.fingerprint=//p' "$1" | head -n1)
	echo "$h ${fp:-unknown}"
}

# overlay_fingerprint -> fingerprint recorded in the current overlay copy.
overlay_fingerprint() {
	fp=$(sed -n 's/^ro.system.build.fingerprint=//p' "$bp" 2>/dev/null | head -n1)
	[ -n "$fp" ] || fp=$(sed -n 's/^ro.build.fingerprint=//p' "$bp" 2>/dev/null | head -n1)
	echo "$fp"
}

seed_build_prop() {
	# seed_build_prop IMAGE_PROPS STAMP
	mkdir -p "$OVERLAY/system" "$STATE_DIR"
	{
		cat "$1"
		printf '\n# waydroid-bt: keep AdapterService bound without HCI HAL\n'
		printf '%s\n' "$OUR_PROPS"
	} >"$bp.tmp"
	chmod 0644 "$bp.tmp"
	mv "$bp.tmp" "$bp"
	echo "$2" >"$SRC_STAMP"
}

# sync_build_prop: (re)seed the overlay copy when it is missing or stale.
sync_build_prop() {
	cur=$(mktemp)
	if ! image_props "$cur"; then
		rm -f "$cur"
		echo "could not read system/build.prop from $IMG" >&2
		return 1
	fi
	new=$(stamp "$cur")
	old=$(cat "$SRC_STAMP" 2>/dev/null || true)
	if [ ! -f "$bp" ]; then
		[ "$MODE" = check ] && { rm -f "$cur"; echo "BUILD_PROP_MISSING"; return 1; }
		seed_build_prop "$cur" "$new"
		echo "BUILD_PROP_SEEDED from $IMG (${new#* })"
	elif [ "$old" = "$new" ]; then
		echo "BUILD_PROP_CURRENT (${new#* })"
	elif [ -z "$old" ] && [ "$(overlay_fingerprint)" = "${new#* }" ]; then
		# Copy from an older version of this script: same image, adopt it.
		[ "$MODE" = check ] || { mkdir -p "$STATE_DIR"; echo "$new" >"$SRC_STAMP"; }
		echo "BUILD_PROP_ADOPTED (${new#* })"
	else
		if [ "$MODE" = check ]; then
			rm -f "$cur"
			echo "BUILD_PROP_STALE overlay=$(overlay_fingerprint) image=${new#* }"
			return 1
		fi
		cp -p "$bp" "$bp.whs-old"
		seed_build_prop "$cur" "$new"
		echo "BUILD_PROP_RESEEDED image changed: $(overlay_fingerprint) (old copy: $bp.whs-old)"
	fi
	rm -f "$cur"
	# Idempotent: make sure our props are present (older copies).
	if [ "$MODE" != check ] && ! grep -q '^ro.bluetooth.ble_start_timeout_delay=' "$bp"; then
		{
			printf '\n# waydroid-bt: keep AdapterService bound without HCI HAL\n'
			printf '%s\n' "$OUR_PROPS"
		} >>"$bp"
		echo "BUILD_PROP_TIMEOUT_ADDED"
	fi
}

# WHS_SELFTEST=1: tests/stabilize-build-prop-selftest.sh (temp overlay, no root).
if [ "$(id -u)" -ne 0 ] && [ "$MODE" != check ] && [ "${WHS_SELFTEST:-0}" != 1 ]; then
	echo "run as root" >&2
	exit 1
fi

if [ "$MODE" = resync ]; then
	# Only manage a copy we seeded (stamp, our props, or one we moved aside).
	if [ ! -f "$SRC_STAMP" ] && [ ! -f "$bp.whs-disabled" ] &&
		! grep -q '^ro.bluetooth.ble_start_timeout_delay=' "$bp" 2>/dev/null; then
		echo "BUILD_PROP_NOT_MANAGED (run with --build-prop-only to seed)"
		exit 0
	fi
	MODE=prop
fi

if [ "$MODE" != full ]; then
	grc=0
	whs_lineage_guard 2>/dev/null || grc=$?
	if [ "$grc" -ne 0 ]; then
		# rc 1: the image is not the generation our props target; never leave
		# a copy of an older image's build.prop over it. (rc 2 = unreadable:
		# leave everything alone.)
		if [ "$grc" -eq 1 ] && [ -f "$bp" ] && [ -f "$SRC_STAMP" ] && [ "$MODE" = prop ]; then
			mv "$bp" "$bp.whs-disabled"
			rm -f "$SRC_STAMP"
			echo "BUILD_PROP_DISABLED image failed the version guard; moved overlay copy to $bp.whs-disabled"
		fi
		exit 0
	fi
	sync_build_prop
	exit $?
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
sync_build_prop

echo "STABILIZE_OK"
echo "Restart Waydroid session for changes to apply."
