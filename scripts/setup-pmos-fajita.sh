#!/bin/sh
# Setup waydroid-bt-host on postmarketOS (oneplus-fajita).
# Run as: doas sh scripts/setup-pmos-fajita.sh
# Or:     sh scripts/setup-pmos-fajita.sh   (if already root)
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ "$(id -u)" -ne 0 ]; then
	echo "This script needs root (doas/sudo)." >&2
	echo "  doas sh $0" >&2
	exit 1
fi

echo "== packages =="
apk update
apk add \
	bluez bluez-btmgmt \
	dbus \
	cargo rust \
	protobuf protobuf-dev \
	pkgconf \
	dbus-dev \
	gcc musl-dev \
	openssl-dev \
	linux-headers \
	wayland-session 2>/dev/null || true

# Waydroid optional for host-daemon bring-up; install for later guest work
apk add waydroid waydroid-systemd 2>/dev/null || apk add waydroid || true

echo "== fix BlueZ seeing HCI (restart after controller is up) =="
hciconfig hci0 up 2>/dev/null || true
systemctl restart bluetooth
sleep 1
btmgmt info || true
bluetoothctl list || true

echo "== build waydroid-bt-host =="
# Prefer user home cargo target if building as root on a copy owned by kb
export CARGO_HOME="${CARGO_HOME:-/home/kb/.cargo}"
export PATH="$CARGO_HOME/bin:/usr/bin:$PATH"
mkdir -p "$CARGO_HOME"
# Build as root in tree; chown later if needed
cargo build --release -p waydroid-bt-host

echo "== install binary + unit =="
install -Dm755 target/release/waydroid-bt-host /usr/bin/waydroid-bt-host
install -Dm755 target/release/waydroid-bt-ping /usr/bin/waydroid-bt-ping 2>/dev/null || true
install -Dm644 host/systemd/waydroid-bt-host.service \
	/usr/lib/systemd/system/waydroid-bt-host.service
install -Dm644 lxc/waydroid-bt-mount.conf /etc/waydroid-bt/lxc-mount.conf
mkdir -p /run/waydroid-bt
systemctl daemon-reload
systemctl enable --now waydroid-bt-host.service
sleep 1
systemctl --no-pager -l status waydroid-bt-host.service || true

echo "== smoke =="
if [ -S /run/waydroid-bt/host.sock ]; then
	waydroid-bt-ping --socket /run/waydroid-bt/host.sock --adapter || true
else
	echo "socket missing; check journalctl -u waydroid-bt-host"
	journalctl -u waydroid-bt-host -n 40 --no-pager || true
fi

echo "== bluetoothctl show =="
bluetoothctl show || true

echo "setup done."
