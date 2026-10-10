#!/bin/sh
# Host bring-up for waydroid-bt-host on a Linux phone (postmarketOS / Nura).
# Device specifics come from devices/<codename>.conf (auto-detected; override
# with WHS_DEVICE=oneplus-enchilada etc.).
#
#   sudo sh scripts/setup-pmos.sh            # detect device + layout
#   WHS_DEVICE=oneplus-fajita sudo sh scripts/setup-pmos.sh
#
# Mutable pmOS (apk works): installs build deps, builds natively, installs.
# Image-based hosts (read-only /usr, e.g. Nura Duranium): no packages, no
# native build — copy prebuilt aarch64 binaries (target/aarch64-unknown-linux-musl/
# release or --bin-dir) and install under /var/lib/waydroid-host-stack.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib/paths.sh
. "$ROOT/scripts/lib/paths.sh"
# shellcheck source=scripts/lib/device.sh
. "$ROOT/scripts/lib/device.sh"

if [ "$(id -u)" -ne 0 ]; then
	echo "This script needs root (sudo/doas)." >&2
	exit 1
fi

whs_resolve_paths
whs_load_device "$ROOT"
echo "== device: $WHS_DEVICE ($DEVICE_NAME) =="

PM="$PKG_MANAGER"
if [ "$PM" = auto ]; then
	if [ "$WHS_IMMUTABLE" = 1 ]; then
		PM=none
	elif command -v apk >/dev/null 2>&1; then
		PM=apk
	else
		PM=none
	fi
fi

if [ "$PM" = apk ]; then
	echo "== packages (apk) =="
	apk update
	apk add bluez bluez-btmgmt dbus cargo rust protobuf protobuf-dev pkgconf \
		dbus-dev gcc musl-dev openssl-dev linux-headers 2>/dev/null || true
	apk add waydroid waydroid-systemd 2>/dev/null || apk add waydroid || true

	echo "== build waydroid-bt-host (native) =="
	bh_user="${SUDO_USER:-${DOAS_USER:-}}"
	if [ -n "$bh_user" ]; then
		bh_home=$(getent passwd "$bh_user" | cut -d: -f6)
		export CARGO_HOME="${CARGO_HOME:-$bh_home/.cargo}"
	fi
	cargo build --release -p waydroid-bt-host -p waydroid-bt-guest-probe
else
	echo "== packages: skipped (PKG_MANAGER=$PM; image-based or no apk) =="
fi

echo "== firmware check =="
for fw in $BT_FIRMWARE; do
	if [ -e "$fw" ]; then echo "ok $fw"; else echo "MISSING $fw"; fi
done

echo "== BlueZ controller =="
systemctl is-active bluetooth || systemctl restart bluetooth || true
bluetoothctl list || true

echo "== install =="
sh "$ROOT/scripts/install-host-system.sh" "$@"

echo "== smoke =="
sleep 1
if [ -S /run/waydroid-bt/host.sock ]; then
	"$BINDIR/waydroid-bt-ping" --socket /run/waydroid-bt/host.sock --adapter || true
else
	echo "socket missing; check journalctl -u waydroid-bt-host"
	journalctl -u waydroid-bt-host -n 40 --no-pager || true
fi
echo "setup done."
