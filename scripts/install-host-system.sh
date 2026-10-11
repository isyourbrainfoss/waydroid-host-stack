#!/bin/sh
# Root installer for the host side of waydroid-host-stack.
# Works on classic mutable hosts AND image-based/immutable hosts (Nura
# "Duranium", other systemd-sysext images) where /usr is read-only.
#
# Installs:
#   $BINDIR      waydroid-bt-host, waydroid-bt-ping, waydroid-bt-jni-patch, waydroid-geoclue-fix
#   $LIBEXECDIR  waydroid-bt-guest-probe
#   $SBINDIR     root helpers (+ $SBINDIR/lib/*.sh)
#   $UNITDIR     waydroid-bt-host.service, waydroid-bt-inject.{service,timer},
#                waydroid-bt-lxc-include.{service,path},
#                waydroid-run-xdg.{service,path},
#                waydroid-geoclue-fix.service, waydroid-gps-inject.service,
#                waydroid-container.service.d/50-waydroid-bt.conf
#   $SYSCONFDIR  lxc-mount.conf (+ device.conf)
#
# Usage (as root, from a repo checkout):
#   sh scripts/install-host-system.sh [--bin-dir DIR] [--dry-run] [--no-enable]
#   sh scripts/install-host-system.sh --print-paths
#   sh scripts/install-host-system.sh --uninstall
#   sh scripts/install-host-system.sh --sysext FILE.raw|DIR   # see build-sysext.sh
#   DESTDIR=/tmp/stage sh scripts/install-host-system.sh --stage-only   # packaging
#
# Paths: see scripts/lib/paths.sh (PREFIX, BINDIR, SBINDIR, LIBEXECDIR, UNITDIR,
# SYSCONFDIR; FORCE_IMMUTABLE=1|0).
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/paths.sh
. "$ROOT/scripts/lib/paths.sh"
# shellcheck source=scripts/lib/device.sh
. "$ROOT/scripts/lib/device.sh"

DRY=0
ENABLE=1
MODE=install
BIN_DIR=""
SYSEXT_SRC=""
DESTDIR="${DESTDIR:-}"

while [ $# -gt 0 ]; do
	case "$1" in
	--dry-run) DRY=1 ;;
	--no-enable) ENABLE=0 ;;
	--print-paths) MODE=print ;;
	--uninstall) MODE=uninstall ;;
	--stage-only) MODE=stage ;;
	--bin-dir) shift; BIN_DIR="$1" ;;
	--sysext) shift; SYSEXT_SRC="$1"; MODE=sysext ;;
	-h | --help) sed -n '2,27p' "$0"; exit 0 ;;
	*) echo "unknown arg: $1" >&2; exit 2 ;;
	esac
	shift
done

whs_resolve_paths

run() {
	if [ "$DRY" = 1 ]; then
		echo "DRY: $*"
	else
		"$@"
	fi
}

if [ "$MODE" = print ]; then
	whs_print_paths
	echo "device=$(whs_detect_device)"
	exit 0
fi

if [ "$MODE" != stage ] && [ "$DRY" = 0 ] && [ "$(id -u)" -ne 0 ]; then
	echo "needs root: sudo sh $0 $*" >&2
	exit 1
fi

waydroid_uid() {
	uid=$(sed -n 's/^waydroid.host.uid=//p' /var/lib/waydroid/waydroid.prop 2>/dev/null | head -n1)
	[ -n "$uid" ] || uid="${SUDO_UID:-}"
	[ -n "$uid" ] || uid=1000
	echo "$uid"
}

# Locate built binaries: --bin-dir, aarch64 musl cross build, native release.
find_bin() {
	name="$1"
	for d in "$BIN_DIR" "$ROOT/target/aarch64-unknown-linux-musl/release" "$ROOT/target/release"; do
		[ -n "$d" ] || continue
		if [ -x "$d/$name" ]; then
			echo "$d/$name"
			return 0
		fi
	done
	return 1
}

subst() {
	# subst SRC DEST — rewrite placeholders/paths for this layout.
	run mkdir -p "$(dirname "$2")"
	if [ "$DRY" = 1 ]; then
		echo "DRY: render $1 -> $2"
		return 0
	fi
	sed -e "s|@SBINDIR@|$SBINDIR|g" \
		-e "s|@WAYDROID_UID@|$(waydroid_uid)|g" \
		-e "s|@WAYDROID_USER@|$(getent passwd "$(waydroid_uid)" | cut -d: -f1)|g" \
		-e "s|@BINDIR@|$BINDIR|g" \
		-e "s|/usr/bin/waydroid-bt-host|$BINDIR/waydroid-bt-host|g" \
		"$1" >"$2"
	chmod 0644 "$2"
}

UNITS="waydroid-bt-host.service waydroid-bt-inject.service waydroid-bt-inject.timer
waydroid-bt-lxc-include.service waydroid-bt-lxc-include.path
waydroid-run-xdg.service waydroid-run-xdg.path
waydroid-geoclue-fix.service waydroid-gps-inject.service"
SBIN_SCRIPTS="waydroid-bt-inject-socket.sh waydroid-bt-session-hook.sh
waydroid-guest-bt-probe.sh waydroid-bt-apply-lxc-include.sh waydroid-run-xdg-bind.sh
waydroid-bt-stabilize-adapter.sh waydroid-restore-bluetooth-apk.sh
waydroid-patch-bt-jni-timerfd.py waydroid-install-soft-hci-hal.sh
waydroid-gps-inject.sh waydroid-bt-diag.sh waydroid-bt-grant-perms.sh waydroid-install-microg.sh"

stage() {
	D="$DESTDIR"
	echo "=== stage host files (DESTDIR=${D:-/}) ==="
	whs_print_paths

	for b in waydroid-bt-host waydroid-bt-ping waydroid-bt-jni-patch waydroid-geoclue-fix; do
		if src=$(find_bin "$b"); then
			run install -Dm0755 "$src" "$D$BINDIR/$b"
		elif [ "$b" = waydroid-bt-host ]; then
			echo "missing $b binary: build with" >&2
			echo "  cargo zigbuild --release --target aarch64-unknown-linux-musl -p waydroid-bt-host -p waydroid-bt-guest-probe --features waydroid-bt-host/vendored-dbus" >&2
			echo "or pass --bin-dir DIR" >&2
			exit 1
		else
			echo "warn: $b not built (optional)"
		fi
	done
	if src=$(find_bin waydroid-bt-guest-probe); then
		run install -Dm0755 "$src" "$D$LIBEXECDIR/waydroid-bt-guest-probe"
	else
		echo "warn: waydroid-bt-guest-probe not built (optional)"
	fi

	for s in $SBIN_SCRIPTS; do
		run install -Dm0755 "$ROOT/scripts/$s" "$D$SBINDIR/$s"
	done
	for l in paths.sh device.sh lineage-guard.sh guest.sh; do
		run install -Dm0644 "$ROOT/scripts/lib/$l" "$D$SBINDIR/lib/$l"
	done
	# Guest HAL launcher/.rc/VINTF manifest for waydroid-install-soft-hci-hal.sh
	for h in bluetooth-hci-waydroid.sh android.hardware.bluetooth@1.0-service.waydroid.rc \
		manifest_android.hardware.bluetooth@1.0.xml; do
		run install -Dm0644 "$ROOT/guest/hal/$h" "$D$SBINDIR/guest-hal/$h"
	done

	subst "$ROOT/host/systemd/waydroid-bt-host.service" "$D$UNITDIR/waydroid-bt-host.service"
	subst "$ROOT/packaging/waydroid-bt-inject.service" "$D$UNITDIR/waydroid-bt-inject.service"
	subst "$ROOT/packaging/waydroid-bt-inject.timer" "$D$UNITDIR/waydroid-bt-inject.timer"
	for u in waydroid-bt-lxc-include.service waydroid-bt-lxc-include.path \
		waydroid-run-xdg.service waydroid-run-xdg.path \
		waydroid-geoclue-fix.service waydroid-gps-inject.service; do
		subst "$ROOT/packaging/systemd/$u" "$D$UNITDIR/$u"
	done
	subst "$ROOT/packaging/systemd/waydroid-container.service.d/50-waydroid-bt.conf" \
		"$D$UNITDIR/waydroid-container.service.d/50-waydroid-bt.conf"
}

stage_etc() {
	D="$DESTDIR"
	run install -Dm0644 "$ROOT/lxc/waydroid-bt-mount.conf" "$D$SYSCONFDIR/lxc-mount.conf"
	run install -Dm0644 "$ROOT/packaging/geoclue/90-waydroid-host-stack.conf" \
		"$D/etc/geoclue/conf.d/90-waydroid-host-stack.conf"
	if [ -n "${WHS_DEVICE_CONF:-}" ]; then
		run install -Dm0644 "$WHS_DEVICE_CONF" "$D$SYSCONFDIR/device.conf"
	fi
}

check_device() {
	whs_load_device "$ROOT"
	echo "device: $WHS_DEVICE ($DEVICE_NAME) config=$WHS_DEVICE_CONF"
	for fw in $BT_FIRMWARE; do
		if [ -e "$fw" ]; then
			echo "  firmware ok: $fw"
		else
			echo "  WARN firmware missing: $fw"
		fi
	done
}

activate() {
	[ "$ENABLE" = 1 ] || { echo "skip enable (--no-enable)"; return 0; }
	run systemctl daemon-reload
	run systemctl enable --now waydroid-bt-host.service
	run systemctl enable --now waydroid-bt-lxc-include.path waydroid-run-xdg.path waydroid-bt-inject.timer
	# GeoClue re-reads conf.d only on restart (it is D-Bus activated; cheap).
	run systemctl try-restart geoclue.service || true
	run systemctl enable waydroid-geoclue-fix.service waydroid-gps-inject.service
	run systemctl restart waydroid-geoclue-fix.service waydroid-gps-inject.service
	run "$SBINDIR/waydroid-bt-apply-lxc-include.sh" || true
	echo "Restart Waydroid to pick up the LXC mount:"
	echo "  waydroid session stop; sudo systemctl restart waydroid-container; waydroid session start"
}

uninstall() {
	for u in waydroid-gps-inject.service waydroid-geoclue-fix.service waydroid-bt-inject.timer waydroid-run-xdg.path waydroid-bt-lxc-include.path waydroid-bt-host.service; do
		run systemctl disable --now "$u" 2>/dev/null || true
	done
	for u in $UNITS; do run rm -f "$UNITDIR/$u"; done
	run rm -f "$UNITDIR/waydroid-container.service.d/50-waydroid-bt.conf"
	run rmdir "$UNITDIR/waydroid-container.service.d" 2>/dev/null || true
	for b in waydroid-bt-host waydroid-bt-ping waydroid-bt-jni-patch waydroid-geoclue-fix; do run rm -f "$BINDIR/$b"; done
	run rm -f "$LIBEXECDIR/waydroid-bt-guest-probe"
	for s in $SBIN_SCRIPTS; do run rm -f "$SBINDIR/$s"; done
	run rm -rf "$SBINDIR/lib" "$SBINDIR/guest-hal"
	cfg="$WAYDROID_LXC_DIR/config"
	if [ -f "$cfg" ] && grep -q "lxc.include = $SYSCONFDIR/lxc-mount.conf" "$cfg"; then
		if [ "$DRY" = 1 ]; then
			echo "DRY: drop include from $cfg"
		else
			tmp="$cfg.whs.$$"
			grep -vxF "lxc.include = $SYSCONFDIR/lxc-mount.conf" "$cfg" >"$tmp" || true
			cat "$tmp" >"$cfg"
			rm -f "$tmp"
		fi
	fi
	run rm -rf "$SYSCONFDIR"
	run rm -f /etc/geoclue/conf.d/90-waydroid-host-stack.conf
	run systemctl daemon-reload
	echo "UNINSTALL_OK"
}

case "$MODE" in
stage)
	stage
	stage_etc
	;;
uninstall) uninstall ;;
sysext)
	check_device
	[ -e "$SYSEXT_SRC" ] || { echo "missing sysext: $SYSEXT_SRC" >&2; exit 1; }
	# Units/binaries come from /usr inside the extension.
	BINDIR=/usr/bin SBINDIR=/usr/libexec/waydroid-host-stack UNITDIR=/usr/lib/systemd/system
	run mkdir -p /var/lib/extensions
	run cp -a "$SYSEXT_SRC" /var/lib/extensions/
	run systemd-sysext refresh
	run systemd-sysext status
	DESTDIR="" stage_etc
	activate
	echo "SYSEXT_INSTALL_OK"
	;;
install)
	check_device
	if [ "$WHS_IMMUTABLE" = 1 ]; then
		echo "image-based host detected (/usr read-only): installing under $PREFIX"
	fi
	DESTDIR=""
	stage
	stage_etc
	activate
	echo "HOST_INSTALL_OK"
	;;
esac
