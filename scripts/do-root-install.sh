#!/bin/sh
# One-shot root bring-up of Waydroid Bluetooth (Soft HCI) on an image-based
# host (Nura Duranium / OnePlus 6). Idempotent; stops at the first failure.
#
#   sudo sh scripts/do-root-install.sh [ARTIFACTS_DIR]
#
# ARTIFACTS_DIR (default: <repo>/artifacts) must contain:
#   bin/waydroid-bt-host bin/waydroid-bt-ping bin/waydroid-bt-jni-patch
#   bin/waydroid-bt-guest-probe
#   android/Bluetooth.apk android/libbluetooth_jni.so      (Lineage 20 TQ3A pair)
#   hal/android.hardware.bluetooth@1.0-service.waydroid
#   SHA256SUMS                                              (verified first)
#
# Log: ~<user>/waydroid-root-install.log (appended; one section per run).
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
ART="${1:-$ROOT/artifacts}"
U="${SUDO_USER:-${DOAS_USER:-kb}}"
UHOME=$(getent passwd "$U" | cut -d: -f6)
UID_N=$(id -u "$U")
LOG="${WHS_LOG:-$UHOME/waydroid-root-install.log}"

if [ "$(id -u)" -ne 0 ]; then
	echo "run with sudo: sudo sh $0 $*" >&2
	exit 1
fi

# --- logging: everything below goes to terminal + $LOG ---
if [ -z "${WHS_LOGGING:-}" ]; then
	touch "$LOG" && chown "$U" "$LOG" 2>/dev/null || true
	export WHS_LOGGING=1
	fifo=$(mktemp -u)
	mkfifo "$fifo"
	tee -a "$LOG" <"$fifo" &
	teepid=$!
	set +e
	sh "$0" "$@" >"$fifo" 2>&1
	rc=$?
	wait "$teepid"
	rm -f "$fifo"
	exit "$rc"
fi

STEP=start
trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo; echo "!!! DO_ROOT_INSTALL_FAILED at step: $STEP (exit $rc) — see $LOG"; fi' EXIT
step() { STEP="$1"; echo; echo "===== [$(date -u +%H:%M:%SZ)] $1 ====="; }

as_user() {
	runuser -u "$U" -- env XDG_RUNTIME_DIR="/run/user/$UID_N" \
		DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_N/bus" \
		WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" HOME="$UHOME" "$@"
}

echo "################ do-root-install $(date -u +%Y-%m-%dT%H:%M:%SZ) ################"
echo "repo=$ROOT artifacts=$ART user=$U uid=$UID_N"

step "1/9 preflight + checksums"
for f in bin/waydroid-bt-host bin/waydroid-bt-jni-patch bin/waydroid-bt-guest-probe \
	android/Bluetooth.apk android/libbluetooth_jni.so \
	hal/android.hardware.bluetooth@1.0-service.waydroid SHA256SUMS; do
	[ -f "$ART/$f" ] || { echo "missing $ART/$f"; exit 1; }
done
(cd "$ART" && sha256sum -c SHA256SUMS)
command -v debugfs >/dev/null || { echo "debugfs missing (needed by lineage guard)"; exit 1; }
systemctl is-active --quiet bluetooth || { echo "bluetooth.service not active"; exit 1; }

step "2/9 host install (install-duranium.sh)"
sh "$ROOT/scripts/install-duranium.sh" --bin-dir "$ART/bin"
. "$ROOT/scripts/lib/paths.sh"
FORCE_IMMUTABLE=1 whs_resolve_paths
systemctl is-active --quiet waydroid-bt-host || { journalctl -u waydroid-bt-host -n 30 --no-pager; exit 1; }
[ -S /run/waydroid-bt/host.sock ] || { echo "host socket missing"; exit 1; }
"$BINDIR/waydroid-bt-ping" --socket /run/waydroid-bt/host.sock --adapter

step "3/9 stop Waydroid session + container"
as_user waydroid session stop 2>/dev/null || true
waydroid container stop 2>/dev/null || true
systemctl stop waydroid-container || true

step "4/9 restore Bluetooth.apk + libbluetooth_jni.so (apex overlay)"
PATH="$BINDIR:$PATH" "$SBINDIR/waydroid-restore-bluetooth-apk.sh" \
	"$ART/android/Bluetooth.apk" "$ART/android/libbluetooth_jni.so" Bluetooth@TQ3A.230901.001

step "5/9 Soft HCI HAL into overlay"
"$SBINDIR/waydroid-install-soft-hci-hal.sh" "$ART/hal/android.hardware.bluetooth@1.0-service.waydroid"

step "6/9 stabilize adapter (JNI timerfd patch + BLE timeouts)"
WAYDROID_BT_JNI_PATCH="$BINDIR/waydroid-bt-jni-patch" "$SBINDIR/waydroid-bt-stabilize-adapter.sh"
"$BINDIR/waydroid-bt-jni-patch" --check \
	/var/lib/waydroid/overlay/system/apex/com.android.btservices/lib64/libbluetooth_jni.so

step "7/9 restart container + session"
"$SBINDIR/waydroid-bt-apply-lxc-include.sh"
systemctl restart waydroid-container
sleep 2
systemctl start waydroid-run-xdg.service || true
as_user systemd-run --user --collect --unit="waydroid-session-rootinstall-$$" waydroid session start
i=0
boot=""
while [ "$i" -lt 150 ]; do
	boot=$(timeout 5 waydroid shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n\t ' || true)
	[ "$boot" = 1 ] && break
	i=$((i + 3)); sleep 3
done
waydroid status || true
[ "$boot" = 1 ] || { echo "guest did not reach sys.boot_completed=1 within 150s"; exit 1; }
echo "guest booted after ~${i}s"

step "8/9 socket inject + guest BT probe"
"$SBINDIR/waydroid-bt-session-hook.sh"
"$SBINDIR/waydroid-guest-bt-probe.sh" "$LIBEXECDIR/waydroid-bt-guest-probe"

step "9/9 Android Bluetooth state"
sleep 5
waydroid shell pm path com.android.bluetooth || true
waydroid shell getprop init.svc.bluetooth-1-0-waydroid || true
waydroid shell pidof android.hardware.bluetooth@1.0-service.waydroid || echo "WARN: Soft HCI HAL process not seen"
timeout 15 waydroid shell dumpsys bluetooth_manager 2>/dev/null | sed -n '1,25p' || true
timeout 10 waydroid shell logcat -d -b main -s bt_hci_waydroid BluetoothManagerService AdapterState 2>/dev/null | tail -40 || true

STEP=finished
echo
echo "DO_ROOT_INSTALL_OK  (log: $LOG)"
