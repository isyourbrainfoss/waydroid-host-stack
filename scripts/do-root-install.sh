#!/bin/sh
# One-shot root bring-up of Waydroid Bluetooth (Soft HCI) on an image-based
# host (Nura Duranium / OnePlus 6). Idempotent; stops at the first failure.
#
#   sudo sh scripts/do-root-install.sh [ARTIFACTS_DIR]   full install + checks
#   sudo sh scripts/do-root-install.sh --diag            diagnostics only
#   sudo sh scripts/do-root-install.sh --microg          host daemon update + microG (Waydroid running)
#   sudo sh scripts/do-root-install.sh --update-host     swap waydroid-bt-host and/or Soft HCI HAL if changed
#   sudo sh scripts/do-root-install.sh --fix-bt          BT perms + toggle + diag (Waydroid running)
#
# Always ends with a guest diagnostic dump (~<user>/waydroid-bt-diag-*.txt) and
# a final DO_ROOT_INSTALL_OK or DO_ROOT_INSTALL_FAILED line.
#
# ARTIFACTS_DIR (default: <repo>/artifacts) must contain:
#   bin/waydroid-bt-host bin/waydroid-bt-ping bin/waydroid-bt-jni-patch
#   bin/waydroid-bt-guest-probe bin/waydroid-geoclue-fix
#   android/Bluetooth.apk android/libbluetooth_jni.so      (Lineage 20 TQ3A pair)
#   hal/android.hardware.bluetooth@1.0-service.waydroid
#   SHA256SUMS                                              (verified first)
#
# Log: ~<user>/waydroid-root-install.log (appended; one section per run).
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
MODE=install
case "${1:-}" in
--diag) MODE=diag; shift ;;
--fix-bt) MODE=fixbt; shift ;;
--microg) MODE=microg; shift ;;
--update-host) MODE=updatehost; shift ;;
esac
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
	case "$MODE" in
	fixbt) set -- --fix-bt "$@" ;;
	diag) set -- --diag "$@" ;;
	microg) set -- --microg "$@" ;;
	updatehost) set -- --update-host "$@" ;;
	esac
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

echo "################ do-root-install $(date -u +%Y-%m-%dT%H:%M:%SZ) mode=$MODE ################"
echo "repo=$ROOT artifacts=$ART user=$U uid=$UID_N"

DIAG="$ROOT/scripts/waydroid-bt-diag.sh"
if [ "$MODE" = microg ] || [ "$MODE" = updatehost ]; then
	# Short mode: update host daemon (GATT write logging) + install microG.
	STEP="host daemon update"
	. "$ROOT/scripts/lib/paths.sh"
	FORCE_IMMUTABLE=1 whs_resolve_paths
	(cd "$ART" && sha256sum -c SHA256SUMS)
	if ! cmp -s "$ART/bin/waydroid-bt-host" "$BINDIR/waydroid-bt-host"; then
		install -m0755 "$ART/bin/waydroid-bt-host" "$BINDIR/waydroid-bt-host"
		systemctl restart waydroid-bt-host
		sleep 1
		systemctl is-active waydroid-bt-host
	fi
	if [ "$MODE" = updatehost ]; then
		HAL_NEW="$ART/hal/android.hardware.bluetooth@1.0-service.waydroid"
		HAL_CUR=/var/lib/waydroid/overlay/system/bin/hw/android.hardware.bluetooth@1.0-service.waydroid
		if ! cmp -s "$HAL_NEW" "$HAL_CUR"; then
			STEP="Soft HCI HAL update"
			"$SBINDIR/waydroid-install-soft-hci-hal.sh" "$HAL_NEW"
			STEP="restart Waydroid for new HAL"
			as_user waydroid session stop 2>/dev/null || true
			systemctl restart waydroid-container
			sleep 2
			systemctl start waydroid-run-xdg.service || true
			as_user systemd-run --user --collect --unit="waydroid-session-updatehal-$$" waydroid session start
			i=0
			boot=""
			while [ "$i" -lt 150 ]; do
				boot=$(timeout 5 waydroid shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n\t ' || true)
				[ "$boot" = 1 ] && break
				i=$((i + 3)); sleep 3
			done
			[ "$boot" = 1 ] || { echo "guest did not boot within 150s"; exit 1; }
			sleep 10
			echo "HAL_UPDATED; guest booted after ~${i}s; bt_state: $(timeout 15 waydroid shell dumpsys bluetooth_manager 2>/dev/null | sed -n 's/^ *state: *//p' | head -n1)"
		fi
		STEP=finished
		echo "DO_ROOT_UPDATE_HOST_OK ($(sha256sum "$BINDIR/waydroid-bt-host" | cut -c1-12))"
		exit 0
	fi
	STEP=microg
	sh "$ROOT/scripts/waydroid-install-microg.sh" "$ART/microg"
	STEP=finished
	echo "DO_ROOT_MICROG_OK"
	exit 0
fi
if [ "$MODE" = diag ]; then
	STEP=diag
	sh "$DIAG" --out "$UHOME/waydroid-bt-diag-$(date -u +%Y%m%d-%H%M%SZ).txt"
	STEP=finished
	echo "DO_ROOT_DIAG_OK"
	exit 0
fi

if [ "$MODE" = install ]; then
step "1/11 preflight + checksums"
for f in bin/waydroid-bt-host bin/waydroid-bt-jni-patch bin/waydroid-bt-guest-probe bin/waydroid-geoclue-fix \
	android/Bluetooth.apk android/libbluetooth_jni.so \
	hal/android.hardware.bluetooth@1.0-service.waydroid SHA256SUMS; do
	[ -f "$ART/$f" ] || { echo "missing $ART/$f"; exit 1; }
done
(cd "$ART" && sha256sum -c SHA256SUMS)
command -v debugfs >/dev/null || { echo "debugfs missing (needed by lineage guard)"; exit 1; }
systemctl is-active --quiet bluetooth || { echo "bluetooth.service not active"; exit 1; }

step "2/11 host install (install-duranium.sh)"
sh "$ROOT/scripts/install-duranium.sh" --bin-dir "$ART/bin"
. "$ROOT/scripts/lib/paths.sh"
FORCE_IMMUTABLE=1 whs_resolve_paths
systemctl is-active --quiet waydroid-bt-host || { journalctl -u waydroid-bt-host -n 30 --no-pager; exit 1; }
[ -S /run/waydroid-bt/host.sock ] || { echo "host socket missing"; exit 1; }
"$BINDIR/waydroid-bt-ping" --socket /run/waydroid-bt/host.sock --adapter

step "3/11 stop Waydroid session + container"
as_user waydroid session stop 2>/dev/null || true
waydroid container stop 2>/dev/null || true
systemctl stop waydroid-container || true

step "4/11 restore Bluetooth.apk + libbluetooth_jni.so (apex overlay)"
PATH="$BINDIR:$PATH" "$SBINDIR/waydroid-restore-bluetooth-apk.sh" \
	"$ART/android/Bluetooth.apk" "$ART/android/libbluetooth_jni.so" Bluetooth@TQ3A.230901.001

step "5/11 Soft HCI HAL into overlay"
"$SBINDIR/waydroid-install-soft-hci-hal.sh" "$ART/hal/android.hardware.bluetooth@1.0-service.waydroid"

step "6/11 stabilize adapter (JNI timerfd patch + BLE timeouts)"
WAYDROID_BT_JNI_PATCH="$BINDIR/waydroid-bt-jni-patch" "$SBINDIR/waydroid-bt-stabilize-adapter.sh"
"$BINDIR/waydroid-bt-jni-patch" --check \
	/var/lib/waydroid/overlay/system/apex/com.android.btservices/lib64/libbluetooth_jni.so

step "7/11 restart container + session"
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

step "8/11 socket inject + guest BT probe"
"$SBINDIR/waydroid-bt-session-hook.sh"
"$SBINDIR/waydroid-guest-bt-probe.sh" "$LIBEXECDIR/waydroid-bt-guest-probe"

fi

export WHS_AUTO_THAW=1  # maintenance: thaw if Waydroid suspends mid-run
# shellcheck source=lib/guest.sh
. "$ROOT/scripts/lib/guest.sh"
bt_state() { gsh 'dumpsys bluetooth_manager' | sed -n 's/^ *state: *//p' | head -n1 | tr -d '\r'; }
PROBLEMS=""
if [ "$MODE" = fixbt ]; then
	step "fix-bt: Waydroid must already be running"
	whs_container_thaw || { echo "container not running — start Waydroid first"; exit 1; }
fi

if [ "$MODE" != fixbt ]; then
step "9/11 location: root GeoClue reader + injector (replaces sudo -n user loop)"
# The user loop idles itself when the root injector is active; also stop it now.
as_user systemctl --user disable --now waydroid-gps-forward.service 2>/dev/null || true
systemctl is-active --quiet waydroid-geoclue-fix.service || { journalctl -u waydroid-geoclue-fix -n 20 --no-pager; PROBLEMS="$PROBLEMS geoclue-fix-not-active"; }
# Ask ModemManager for GNSS too (works without SIM here; GeoClue's modem-gps uses it).
mmcli -m any --location-enable-gps-nmea --location-enable-gps-raw 2>&1 || echo "WARN: mmcli GNSS enable failed (GeoClue WiFi/IP fallback still works)"
i=0
while [ ! -s /run/waydroid-host-stack/gps-fix ] && [ "$i" -lt 60 ]; do i=$((i + 2)); sleep 2; done
echo "host fix: $(cat /run/waydroid-host-stack/gps-fix 2>/dev/null || echo NONE)"
whs_container_thaw || PROBLEMS="$PROBLEMS container-not-running"
if "$SBINDIR/waydroid-gps-inject.sh" once; then
	gsh 'dumpsys location | grep -iE "last location|test provider|gps provider" | head -12' || true
else
	PROBLEMS="$PROBLEMS gps-inject-failed"
fi

fi
step "10/11 Android Bluetooth: grant runtime perms, then toggle once if stuck"
whs_container_thaw || true
sh "$ROOT/scripts/waydroid-bt-grant-perms.sh" || PROBLEMS="$PROBLEMS bt-perms"
# The Bluetooth process that booted without BLUETOOTH_CONNECT stays wedged in
# BLE_TURNING_ON (USER_TURN_OFF/ON are "Unhandled" there), and granting does not
# restart it. Kill it once; BluetoothManagerService rebinds and re-enables with
# the new grants.
if [ "$(bt_state)" != ON ]; then
	old=$(gsh 'pidof com.android.bluetooth' | tr -d '\r\n')
	echo "restarting com.android.bluetooth (pid ${old:-none}) to pick up grants"
	[ -n "$old" ] && gsh "kill -9 $old" || true
	i=0
	while [ "$i" -lt 30 ]; do
		new=$(gsh 'pidof com.android.bluetooth' | tr -d '\r\n')
		[ -n "$new" ] && [ "$new" != "$old" ] && break
		i=$((i + 2)); sleep 2
	done
	echo "com.android.bluetooth new pid=${new:-none} after ${i}s"
	gsh 'cmd bluetooth_manager enable' || true
fi
st=""
i=0
while [ "$i" -lt 30 ]; do
	st=$(bt_state)
	[ "$st" = ON ] && break
	i=$((i + 3)); sleep 3
done
echo "bt_state=$st after ${i}s"
if [ "$st" != ON ]; then
	echo "Bluetooth not ON — toggling once (disable/enable)"
	gsh 'cmd bluetooth_manager disable; sleep 4; cmd bluetooth_manager enable' || true
	i=0
	while [ "$i" -lt 30 ]; do
		st=$(bt_state)
		[ "$st" = ON ] && break
		i=$((i + 3)); sleep 3
	done
	echo "bt_state=$st after toggle"
fi
gsh 'dumpsys bluetooth_manager' | sed -n '1,25p'
[ "$st" = ON ] || PROBLEMS="$PROBLEMS android-bt-not-on($st)"

step "11/11 guest diagnostics dump"
sh "$DIAG" --out "$UHOME/waydroid-bt-diag-$(date -u +%Y%m%d-%H%M%SZ).txt" || true

STEP=finished
echo
if [ -n "$PROBLEMS" ]; then
	echo "DO_ROOT_INSTALL_FAILED:$PROBLEMS  (install steps done; see diag file + $LOG)"
	exit 0
fi
echo "DO_ROOT_INSTALL_OK  (log: $LOG)"
