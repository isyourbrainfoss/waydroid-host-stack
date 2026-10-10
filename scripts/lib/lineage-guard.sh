# shellcheck shell=sh
# Guard: only apply the Bluetooth APK restore / JNI timerfd patch to the
# Android generation they were built and verified for:
#   Lineage 20 / Android 13, SDK 33, build id TQ3A.* (e.g. TQ3A.230901.001)
#
# Reads build.prop without booting Android when possible:
#   1) debugfs -R 'cat /system/build.prop' system.img   (no mount, no root write)
#   2) read-only loop mount of system.img                (root)
#   3) `waydroid shell getprop` if the session is fully booted
#
# Override (at your own risk): WAYDROID_BT_SKIP_VERSION_GUARD=1
# Change targets: WAYDROID_BT_REQUIRED_SDK=33 WAYDROID_BT_REQUIRED_BUILD_PREFIX=TQ3A

: "${WAYDROID_SYSTEM_IMG:=/var/lib/waydroid/images/system.img}"
: "${WAYDROID_BT_REQUIRED_SDK:=33}"
: "${WAYDROID_BT_REQUIRED_BUILD_PREFIX:=TQ3A}"

# Print system build.prop content on stdout (empty on failure).
whs_read_build_prop() {
	img="$WAYDROID_SYSTEM_IMG"
	if [ -f "$img" ] && command -v debugfs >/dev/null 2>&1; then
		out=$(debugfs -R 'cat /system/build.prop' "$img" 2>/dev/null || true)
		if printf '%s\n' "$out" | grep -q '^ro.build.version.sdk='; then
			printf '%s\n' "$out"
			return 0
		fi
	fi
	if [ -f "$img" ] && [ "$(id -u)" -eq 0 ]; then
		mnt=$(mktemp -d)
		if mount -o ro,loop "$img" "$mnt" 2>/dev/null; then
			cat "$mnt/system/build.prop" 2>/dev/null || true
			umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
			rmdir "$mnt" 2>/dev/null || true
			return 0
		fi
		rmdir "$mnt" 2>/dev/null || true
	fi
	if command -v waydroid >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
		sdk=$(timeout 5 waydroid shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r\n\t ' || true)
		bid=$(timeout 5 waydroid shell getprop ro.build.id 2>/dev/null | tr -d '\r\n\t ' || true)
		if [ -n "$sdk" ]; then
			echo "ro.build.version.sdk=$sdk"
			echo "ro.build.id=$bid"
			return 0
		fi
	fi
	return 1
}

# whs_prop_get PROPTEXT KEY
whs_prop_get() {
	printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n1
}

# Exit status 0 = supported generation; prints a one-line verdict.
whs_lineage_guard() {
	if [ "${WAYDROID_BT_SKIP_VERSION_GUARD:-0}" = "1" ]; then
		echo "LINEAGE_GUARD_SKIPPED (WAYDROID_BT_SKIP_VERSION_GUARD=1)" >&2
		return 0
	fi
	props=$(whs_read_build_prop || true)
	if [ -z "$props" ]; then
		echo "LINEAGE_GUARD_FAIL: cannot read build.prop from $WAYDROID_SYSTEM_IMG (install debugfs/e2fsprogs or run as root)" >&2
		return 2
	fi
	sdk=$(whs_prop_get "$props" ro.build.version.sdk)
	bid=$(whs_prop_get "$props" ro.build.id)
	fp=$(whs_prop_get "$props" ro.system.build.fingerprint)
	[ -n "$fp" ] || fp=$(whs_prop_get "$props" ro.build.fingerprint)
	case "$bid" in
	"$WAYDROID_BT_REQUIRED_BUILD_PREFIX"*) bid_ok=1 ;;
	*) bid_ok=0 ;;
	esac
	if [ "$sdk" = "$WAYDROID_BT_REQUIRED_SDK" ] && [ "$bid_ok" = 1 ]; then
		echo "LINEAGE_GUARD_OK sdk=$sdk build_id=$bid fingerprint=${fp:-?}" >&2
		return 0
	fi
	echo "LINEAGE_GUARD_FAIL: image sdk=${sdk:-?} build_id=${bid:-?} (need sdk=$WAYDROID_BT_REQUIRED_SDK build_id=$WAYDROID_BT_REQUIRED_BUILD_PREFIX*)" >&2
	echo "  The APK restore / JNI timerfd patch offsets are only valid for Lineage 20 TQ3A." >&2
	return 1
}
