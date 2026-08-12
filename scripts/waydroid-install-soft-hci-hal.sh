#!/bin/sh
# Install soft IBluetoothHci HAL + init wrapper into Waydroid overlay (fajita).
# Usage (on phone, root):
#   sudo waydroid-install-soft-hci-hal.sh /path/to/android.hardware.bluetooth@1.0-service.waydroid
set -eu

BIN="${1:-}"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
	echo "usage: $0 /path/to/android.hardware.bluetooth@1.0-service.waydroid" >&2
	exit 1
fi

OVERLAY="${WAYDROID_OVERLAY:-/var/lib/waydroid/overlay}"
REPO_HAL="${WAYDROID_BT_HAL_SRC:-}"

install -D -m 0755 "$BIN" \
	"$OVERLAY/system/bin/hw/android.hardware.bluetooth@1.0-service.waydroid"

# Wrapper with LD_LIBRARY_PATH
if [ -n "$REPO_HAL" ] && [ -f "$REPO_HAL/bluetooth-hci-waydroid.sh" ]; then
	install -D -m 0755 "$REPO_HAL/bluetooth-hci-waydroid.sh" \
		"$OVERLAY/system/bin/bluetooth-hci-waydroid"
else
	# Keep embedded fallback in sync with guest/hal/bluetooth-hci-waydroid.sh
	cat >"$OVERLAY/system/bin/bluetooth-hci-waydroid" <<'WRAP'
#!/system/bin/sh
# Soft HCI HAL launcher (oneshot-safe, single instance via pidof + optional flock).
export LD_LIBRARY_PATH=/system/lib64:/system/lib${LD_LIBRARY_PATH:+:}$LD_LIBRARY_PATH
HAL=/system/bin/hw/android.hardware.bluetooth@1.0-service.waydroid
LOCKDIR=/data/local/tmp/waydroid-bt
LOCK=$LOCKDIR/soft-hci.lock
PIDFILE=$LOCKDIR/soft-hci.pid
mkdir -p "$LOCKDIR" 2>/dev/null || true
if /system/bin/pidof android.hardware.bluetooth@1.0-service.waydroid >/dev/null 2>&1; then
	exit 0
fi
if /system/bin/ps -A 2>/dev/null | /system/bin/grep -q '[a]ndroid.hardware.bluetooth@1.0-service.waydroid'; then
	exit 0
fi
if [ -f "$PIDFILE" ]; then
	old=$(cat "$PIDFILE" 2>/dev/null || true)
	if [ -n "$old" ] && [ -d "/proc/$old" ]; then
		if /system/bin/tr '\0' ' ' <"/proc/$old/cmdline" 2>/dev/null | /system/bin/grep -q 'android.hardware.bluetooth@1.0-service.waydroid'; then
			exit 0
		fi
	fi
	rm -f "$PIDFILE" 2>/dev/null || true
fi
if [ -x /system/bin/flock ] || command -v flock >/dev/null 2>&1; then
	FLOCK=$(command -v flock 2>/dev/null || echo /system/bin/flock)
	exec $FLOCK -n "$LOCK" /system/bin/sh -c "
		if /system/bin/pidof android.hardware.bluetooth@1.0-service.waydroid >/dev/null 2>&1; then
			exit 0
		fi
		$HAL >/dev/null 2>&1 &
		echo \$! > '$PIDFILE'
		exit 0
	"
fi
$HAL >/dev/null 2>&1 &
echo $! >"$PIDFILE" 2>/dev/null || true
exit 0
WRAP
	chmod 0755 "$OVERLAY/system/bin/bluetooth-hci-waydroid"
fi


# Init rc: start via wrapper when hwservicemanager is ready
if [ -n "$REPO_HAL" ] && [ -f "$REPO_HAL/android.hardware.bluetooth@1.0-service.waydroid.rc" ]; then
	install -D -m 0644 "$REPO_HAL/android.hardware.bluetooth@1.0-service.waydroid.rc" \
		"$OVERLAY/system/etc/init/android.hardware.bluetooth@1.0-service.waydroid.rc"
else
	cat >"$OVERLAY/system/etc/init/android.hardware.bluetooth@1.0-service.waydroid.rc" <<'RC'
service bluetooth-1-0-waydroid /system/bin/bluetooth-hci-waydroid
    class main
    user root
    group root
    oneshot
    disabled

on property:hwservicemanager.ready=true
    start bluetooth-1-0-waydroid

on property:sys.boot_completed=1
    start bluetooth-1-0-waydroid
RC
	chmod 0644 "$OVERLAY/system/etc/init/android.hardware.bluetooth@1.0-service.waydroid.rc"
fi



# Device VINTF fragment (vendor)
install -D -m 0644 /dev/stdin \
	"$OVERLAY/vendor/etc/vintf/manifest/android.hardware.bluetooth@1.0-service.waydroid.xml" <<'XML'
<manifest version="1.0" type="device">
    <hal format="hidl">
        <name>android.hardware.bluetooth</name>
        <transport>hwbinder</transport>
        <version>1.0</version>
        <interface>
            <name>IBluetoothHci</name>
            <instance>default</instance>
        </interface>
        <fqname>@1.0::IBluetoothHci/default</fqname>
    </hal>
</manifest>
XML

echo "INSTALL_OK overlay=$OVERLAY"
ls -la "$OVERLAY/system/bin/hw/android.hardware.bluetooth@1.0-service.waydroid" \
	"$OVERLAY/system/bin/bluetooth-hci-waydroid" \
	"$OVERLAY/system/etc/init/android.hardware.bluetooth@1.0-service.waydroid.rc"
