#!/bin/sh
# Install official microG (GmsCore + companion/FakeStore "com.android.vending")
# into a running Waydroid guest as regular (updatable) apps — no image/overlay
# changes, fully reversible with `pm uninstall`.
#
# Why: apps like Tesla need Google Play services APIs (account login, FCM push,
# location/BLE helpers). VANILLA Waydroid images ship none. LineageOS 20 Waydroid
# images include Lineage's *restricted* signature spoofing (services.jar handles
# the `fake-signature` meta-data only for the official microG signing key), so
# the official microG release APKs work without patching the image.
#
#   sudo waydroid-install-microg.sh DIR      # DIR has com.google.android.gms-*.apk
#                                            # and com.android.vending-*.apk
#   sudo waydroid-install-microg.sh --uninstall
set -u
# shellcheck source=lib/guest.sh
. "$(CDPATH='' cd -- "$(dirname "$0")" && pwd)/lib/guest.sh"

whs_container_thaw || { echo "MICROG_FAILED container not running (start Waydroid first)"; exit 1; }
[ "$(gsh 'getprop sys.boot_completed' | tr -d '\r\n ')" = 1 ] || { echo "MICROG_FAILED guest not booted"; exit 1; }

if [ "${1:-}" = "--uninstall" ]; then
	gsh 'pm uninstall com.android.vending; pm uninstall com.google.android.gms'
	echo MICROG_UNINSTALLED
	exit 0
fi
DIR="${1:?usage: $0 DIR|--uninstall}"

# pm install from stdin (-S size) so nothing has to be staged in guest /data.
install_apk() {
	apk="$1"
	size=$(wc -c <"$apk" | tr -d ' ')
	echo "installing $(basename "$apk") ($size bytes)"
	timeout -k 3 300 lxc-attach -P "$WHS_LXC_PATH" -n waydroid --clear-env \
		-v PATH=/product/bin:/apex/com.android.runtime/bin:/system/bin:/system/xbin:/vendor/bin \
		-v ANDROID_ROOT=/system -v ANDROID_DATA=/data -v HOME=/data \
		-- /system/bin/pm install -r -g -S "$size" <"$apk" 2>&1
}

rc=0
for pat in 'com.google.android.gms-*.apk' 'com.android.vending-*.apk'; do
	# shellcheck disable=SC2086,SC2010
	apk=$(ls "$DIR"/$pat 2>/dev/null | grep -v -- '-hw\.apk$' | head -n1)
	[ -n "$apk" ] || { echo "missing $DIR/$pat"; rc=1; continue; }
	out=$(install_apk "$apk")
	echo "$out"
	case "$out" in *Success*) ;; *) rc=1 ;; esac
done

# Runtime perms GmsCore needs for location / nearby / account features.
gsh '
G=com.google.android.gms
for p in ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION ACCESS_BACKGROUND_LOCATION \
         BLUETOOTH_CONNECT BLUETOOTH_SCAN BLUETOOTH_ADVERTISE READ_PHONE_STATE \
         GET_ACCOUNTS POST_NOTIFICATIONS RECEIVE_SMS; do
  pm grant $G android.permission.$p 2>/dev/null && echo "granted $p"
done
cmd deviceidle whitelist +$G >/dev/null 2>&1
echo "--- installed"
pm list packages --show-versioncode | grep -E "com.google.android.gms|com.android.vending"
dumpsys package com.google.android.gms | grep -E "versionName|signatures" | head -3
'
if [ "$rc" = 0 ]; then
	echo "MICROG_OK — open 'microG Settings' in Waydroid: Self-Check (signature spoofing must be ticked),"
	echo "  enable Google device registration + Cloud Messaging, add Google account if the app needs it."
else
	echo "MICROG_FAILED"
fi
exit "$rc"
