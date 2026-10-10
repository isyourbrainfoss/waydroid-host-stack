#!/bin/sh
# Root diagnostics for Waydroid Bluetooth (Soft HCI) and location injection.
# Read-only except for the optional --toggle (Bluetooth off/on in the guest).
#
#   sudo waydroid-bt-diag.sh [--toggle] [--out FILE]
#
# Writes FILE (default ~<sudo user>/waydroid-bt-diag-<UTC>.txt) plus FILE.logcat.gz
# (full guest logcat) and chowns both to the invoking user.
set -u

LXC_PATH="${WAYDROID_LXC_PATH:-/var/lib/waydroid/lxc}"
U="${SUDO_USER:-${DOAS_USER:-kb}}"
UHOME=$(getent passwd "$U" | cut -d: -f6)
TOGGLE=0
OUT=""
while [ $# -gt 0 ]; do
	case "$1" in
	--toggle) TOGGLE=1 ;;
	--out) shift; OUT="$1" ;;
	*) echo "usage: $0 [--toggle] [--out FILE]" >&2; exit 2 ;;
	esac
	shift
done
[ -n "$OUT" ] || OUT="$UHOME/waydroid-bt-diag-$(date -u +%Y%m%d-%H%M%SZ).txt"
if [ "$(id -u)" -ne 0 ]; then
	echo "run as root" >&2
	exit 1
fi

gsh() {
	timeout 30 lxc-attach -P "$LXC_PATH" -n waydroid --clear-env \
		-v PATH=/product/bin:/apex/com.android.runtime/bin:/system/bin:/system/xbin:/vendor/bin \
		-v ANDROID_ROOT=/system -v ANDROID_DATA=/data -v HOME=/data \
		-- /system/bin/sh -c "$1" 2>&1
}
sec() { printf '\n########## %s ##########\n' "$1"; }
run() { sec "$*"; sh -c "$*" 2>&1; }
g() { sec "guest: $1"; gsh "$1"; }

bt_state() {
	gsh 'dumpsys bluetooth_manager' | sed -n 's/^ *state: *//p' | head -n1
}

{
	echo "waydroid-bt-diag $(date -u +%Y-%m-%dT%H:%M:%SZ) host=$(uname -n) kernel=$(uname -r)"
	run "systemctl --no-pager status waydroid-bt-host waydroid-container waydroid-geoclue-fix waydroid-gps-inject | cat"
	run "journalctl -u waydroid-bt-host -n 80 --no-pager"
	run "journalctl -u waydroid-gps-inject -u waydroid-geoclue-fix -n 40 --no-pager"
	run "cat /run/waydroid-host-stack/gps-fix; /var/lib/waydroid-host-stack/sbin/waydroid-gps-inject.sh status"
	run "bluetoothctl show | head -12; rfkill"
	run "ls -la /run/waydroid-bt; waydroid status"
	run "tail -5 /var/lib/waydroid/lxc/waydroid/config; cat /var/lib/waydroid/waydroid.cfg"
	run "cd /var/lib/waydroid/overlay && find . -type f | sort | xargs -r sha256sum"
	run "ls -Z /sys/fs/selinux 2>/dev/null | head -3; cat /sys/fs/selinux/enforce 2>/dev/null || echo no-selinuxfs"

	PID=$(lxc-info -P "$LXC_PATH" -n waydroid -pH 2>/dev/null || true)
	sec "container pid=$PID"
	if [ -z "$PID" ] || [ "$PID" = "-1" ]; then
		echo "CONTAINER_NOT_RUNNING"
	else
		g 'getprop | grep -iE "bluetooth|bt\.|hwservicemanager|boot_completed|vintf|selinux|init.svc.blue|ro.build.(id|fingerprint)"'
		g 'getenforce 2>/dev/null; id'
		g 'ps -A -o PID,USER,NAME,S | grep -iE "bluetooth|hwservice|servicemanager|hci|com.android.bluetooth"'
		g 'for p in $(pidof android.hardware.bluetooth@1.0-service.waydroid); do echo "HAL pid=$p"; cat /proc/$p/status | head -12; ls -l /proc/$p/fd 2>/dev/null; done'
		g 'lshal -i 2>/dev/null | grep -iE "bluetooth|Interface" | head -20 || echo "lshal unavailable"'
		g 'lshal debug android.hardware.bluetooth@1.0::IBluetoothHci/default 2>&1 | head -5'
		g 'ls -la /vendor/etc/vintf/manifest/ /system/bin/hw/ /system/etc/init/ | grep -iE "blue|total|^/"'
		g 'cat /vendor/etc/vintf/manifest/android.hardware.bluetooth@1.0-service.waydroid.xml'
		g 'ls -la /run/waydroid-bt /dev/socket/waydroid_bt /data/local/tmp/waydroid-bt 2>&1'
		g 'ls -la /apex/com.android.btservices/app/*/ /apex/com.android.btservices/lib64/libbluetooth_jni.so; pm path com.android.bluetooth'
		g 'getprop ro.bluetooth.ble_start_timeout_delay; grep -n ble_ /system/build.prop'
		g 'dumpsys bluetooth_manager | head -60'
		g 'ls -la /data/misc/bluetooth /data/misc/bluetooth/logs /data/tombstones 2>&1 | head -40'
		g 'logcat -d -b crash | tail -80'
		g 'logcat -d -b all -v threadtime | grep -iE "bt_hci_waydroid|Soft HCI|bluetooth|bt_stack|bt_btif|bt_hci|hci_hal|HidlServiceManagement|hwservicemanager|vintf|BluetoothManager|AdapterState|AdapterService|avc:" | tail -400'
		g 'dmesg 2>/dev/null | grep -iE "avc|bluetooth|binder" | tail -40'
		gsh 'logcat -d -b all -v threadtime' | gzip >"$OUT.logcat.gz"
		echo "full logcat: $OUT.logcat.gz"

		if [ "$TOGGLE" = 1 ]; then
			sec "toggle Bluetooth (before: $(bt_state))"
			gsh 'cmd bluetooth_manager disable; sleep 4; cmd bluetooth_manager enable'
			sleep 15
			echo "after toggle: $(bt_state)"
			g 'dumpsys bluetooth_manager | head -30'
			g 'logcat -d -b all -v threadtime | grep -iE "bt_hci_waydroid|Soft HCI|hci_hal|AdapterState|BluetoothManager" | tail -120'
		fi
		sec "SUMMARY"
		echo "bt_state=$(bt_state)"
		echo "hal_pid=$(gsh 'pidof android.hardware.bluetooth@1.0-service.waydroid' | tr -d '\r\n')"
		echo "hal_connected_to_host=$(journalctl -u waydroid-bt-host --since '-30min' --no-pager 2>/dev/null | grep -c 'guest client connected')"
	fi
} >"$OUT" 2>&1
chown "$U" "$OUT" "$OUT.logcat.gz" 2>/dev/null || true
echo "BT_DIAG_WRITTEN $OUT"
