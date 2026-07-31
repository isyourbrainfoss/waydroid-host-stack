#!/bin/sh
# Restore com.android.bluetooth into a Waydroid Lineage-20 (A13) image overlay.
#
# Waydroid strips the Bluetooth app from com.android.btservices (see
# waydroid-patches/.../0001-hack-Remove-Bluetooth-app-from-apex.patch). Framework
# jars + libbluetooth_jni.so remain; apps then hit "Bluetooth Service not connected".
#
# This script overlays:
#   1) Bluetooth.apk into the flattened apex app/ tree (required for JNI namespace)
#   2) optional matching libbluetooth_jni.so (APK and .so must be same build)
#   3) privapp allowlist + bluetooth feature XML
#
# Do NOT install only as /system/priv-app — PackageManager will pick that codePath
# and then fail with: UnsatisfiedLinkError: libbluetooth_jni.so not found.
#
# Obtain a matching A13 arm64 pair, e.g. from Lineage 20 (SDK 33) device ROM:
#   apex: system/apex/com.android.btservices.apex
#   paths inside apex_payload.img:
#     /app/Bluetooth@TQ3A.*/Bluetooth.apk
#     /lib64/libbluetooth_jni.so
#
# Usage:
#   sudo waydroid-restore-bluetooth-apk.sh /path/to/Bluetooth.apk \
#       [/path/to/libbluetooth_jni.so] [version_dir]
#
# version_dir defaults to Bluetooth@TQ3A.230901.001 (matches current waydroid builds).
#
# After install, restart Waydroid:
#   waydroid session stop
#   sudo systemctl restart waydroid-container
#   waydroid session start
#
# Expected after boot:
#   sudo waydroid shell pm path com.android.bluetooth
#     -> package:/apex/com.android.btservices/app/Bluetooth@.../Bluetooth.apk
#
# Note: full Fluoride stack still needs a BT HAL (or a host-bridge replacement).
# Without it AdapterService may abort during stack init (timerfd / HalVersionManager).
set -eu

APK="${1:-}"
JNI="${2:-}"
VERSION_DIR="${3:-Bluetooth@TQ3A.230901.001}"

# Allow: script.apk [version_dir]  OR  script.apk jni.so [version_dir]
if [ -n "${JNI}" ] && [ ! -f "${JNI}" ]; then
	VERSION_DIR="${JNI}"
	JNI=""
fi

OVERLAY="${WAYDROID_OVERLAY:-/var/lib/waydroid/overlay}"
APEX_ROOT="$OVERLAY/system/apex/com.android.btservices"
APEX_APP_DIR="$APEX_ROOT/app/$VERSION_DIR"
APEX_LIB_DIR="$APEX_ROOT/lib64"
PERM_DIR="$OVERLAY/system/etc/permissions"

if [ "$(id -u)" -ne 0 ]; then
	echo "run as root" >&2
	exit 1
fi
if [ -z "$APK" ] || [ ! -f "$APK" ]; then
	echo "usage: $0 /path/to/Bluetooth.apk [/path/to/libbluetooth_jni.so] [version_dir]" >&2
	exit 1
fi

if command -v aapt >/dev/null 2>&1; then
	pkg=$(aapt dump badging "$APK" 2>/dev/null | sed -n "s/package: name='\([^']*\)'.*/\1/p" | head -1)
	echo "apk package name: ${pkg:-unknown}"
	if [ -n "$pkg" ] && [ "$pkg" != "com.android.bluetooth" ]; then
		echo "ERROR: expected com.android.bluetooth, got $pkg" >&2
		exit 1
	fi
fi

# Remove stale priv-app install so PM binds the apex codePath (JNI-safe).
if [ -d "$OVERLAY/system/priv-app/Bluetooth" ]; then
	echo "removing overlay priv-app/Bluetooth (apex path preferred)"
	rm -rf "$OVERLAY/system/priv-app/Bluetooth"
fi

mkdir -p "$APEX_APP_DIR"
install -m644 "$APK" "$APEX_APP_DIR/Bluetooth.apk"
echo "APEX_INSTALLED $APEX_APP_DIR/Bluetooth.apk"

if [ -n "$JNI" ] && [ -f "$JNI" ]; then
	mkdir -p "$APEX_LIB_DIR"
	install -m644 "$JNI" "$APEX_LIB_DIR/libbluetooth_jni.so"
	echo "JNI_INSTALLED $APEX_LIB_DIR/libbluetooth_jni.so"
else
	echo "JNI_SKIPPED (using image libbluetooth_jni.so — must match APK build)"
fi

mkdir -p "$PERM_DIR"
cat >"$PERM_DIR/privapp-permissions-com.android.bluetooth.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<permissions>
    <privapp-permissions package="com.android.bluetooth">
        <permission name="android.permission.BLUETOOTH_PRIVILEGED" />
        <permission name="android.permission.CONTROL_INCALL_EXPERIENCE" />
        <permission name="android.permission.READ_PRIVILEGED_PHONE_STATE" />
        <permission name="android.permission.NFC_HANDOVER_STATUS" />
        <permission name="android.permission.WRITE_SECURE_SETTINGS" />
        <permission name="android.permission.WRITE_APN_SETTINGS" />
        <permission name="android.permission.CALL_PRIVILEGED" />
        <permission name="android.permission.CONNECTIVITY_INTERNAL" />
        <permission name="android.permission.TETHER_PRIVILEGED" />
        <permission name="android.permission.MODIFY_PHONE_STATE" />
        <permission name="android.permission.INTERACT_ACROSS_USERS" />
        <permission name="android.permission.INTERACT_ACROSS_USERS_FULL" />
        <permission name="android.permission.MANAGE_USERS" />
        <permission name="android.permission.MEDIA_CONTENT_CONTROL" />
        <permission name="android.permission.UPDATE_APP_OPS_STATS" />
        <permission name="android.permission.REAL_GET_TASKS" />
        <permission name="android.permission.MODIFY_AUDIO_ROUTING" />
        <permission name="android.permission.UPDATE_DEVICE_STATS" />
        <permission name="android.permission.PACKAGE_USAGE_STATS" />
        <permission name="android.permission.START_FOREGROUND_SERVICES_FROM_BACKGROUND" />
        <permission name="android.permission.WRITE_SECURITY_LOG" />
        <permission name="android.permission.LOG_COMPAT_CHANGE" />
        <permission name="android.permission.READ_COMPAT_CHANGE_CONFIG" />
        <permission name="android.permission.LOCAL_MAC_ADDRESS" />
        <permission name="android.permission.DUMP" />
        <permission name="android.permission.RECEIVE_BOOT_COMPLETED" />
        <permission name="android.permission.START_ACTIVITIES_FROM_BACKGROUND" />
        <permission name="android.permission.BLUETOOTH_CONNECT" />
        <permission name="android.permission.BLUETOOTH_SCAN" />
        <permission name="android.permission.BLUETOOTH_ADVERTISE" />
        <permission name="android.permission.ACCESS_FINE_LOCATION" />
        <permission name="android.permission.ACCESS_COARSE_LOCATION" />
        <permission name="android.permission.NETWORK_SETTINGS" />
        <permission name="android.permission.VIBRATE" />
        <permission name="android.permission.WAKE_LOCK" />
        <permission name="android.permission.GET_TASKS" />
        <permission name="android.permission.NFC" />
        <permission name="android.permission.POST_NOTIFICATIONS" />
    </privapp-permissions>
</permissions>
XML

cat >"$PERM_DIR/android.hardware.bluetooth.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<permissions>
    <feature name="android.hardware.bluetooth" />
    <feature name="android.hardware.bluetooth_le" />
</permissions>
XML

echo "OVERLAY_OK"
find "$OVERLAY/system/apex/com.android.btservices" "$PERM_DIR" -type f 2>/dev/null | sort
echo "Restart Waydroid session for changes to apply."
