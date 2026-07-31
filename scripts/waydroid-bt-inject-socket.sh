#!/bin/sh
# Bind host /run/waydroid-bt into a RUNNING Waydroid LXC mount namespace.
# Idempotent: re-binds if the guest path is missing the socket after a remount race.
set -eu

HOSTDIR="${WAYDROID_BT_HOSTDIR:-/run/waydroid-bt}"
GUESTDIR="${WAYDROID_BT_GUESTDIR:-/run/waydroid-bt}"
SOCK="$HOSTDIR/host.sock"
LXC_PATH="${WAYDROID_LXC_PATH:-/var/lib/waydroid/lxc}"

if [ "$(id -u)" -ne 0 ]; then
	echo "run as root (sudo $0)" >&2
	exit 1
fi

# Host service must be up for a live socket
if [ ! -S "$SOCK" ]; then
	if command -v systemctl >/dev/null 2>&1; then
		systemctl start waydroid-bt-host 2>/dev/null || true
		# brief wait for socket
		w=0
		while [ "$w" -lt 15 ] && [ ! -S "$SOCK" ]; do
			w=$((w + 1))
			sleep 0.2 2>/dev/null || sleep 1
		done
	fi
fi

if [ ! -S "$SOCK" ]; then
	echo "missing host socket: $SOCK (is waydroid-bt-host running?)" >&2
	exit 1
fi

PID=$(lxc-info -P "$LXC_PATH" -n waydroid -pH 2>/dev/null || true)
if [ -z "${PID:-}" ] || [ "$PID" = "-1" ]; then
	echo "waydroid container not running" >&2
	exit 1
fi

GUEST_MNT="/proc/$PID/root$GUESTDIR"
mkdir -p "$GUEST_MNT"

need_bind=0
if ! mountpoint -q "$GUEST_MNT" 2>/dev/null; then
	need_bind=1
elif [ ! -S "$GUEST_MNT/host.sock" ]; then
	# Stale/empty mount — remount
	umount "$GUEST_MNT" 2>/dev/null || true
	need_bind=1
fi

if [ "$need_bind" -eq 1 ]; then
	mount --bind "$HOSTDIR" "$GUEST_MNT"
fi

if [ ! -S "$GUEST_MNT/host.sock" ]; then
	echo "inject failed: guest $GUESTDIR/host.sock missing after bind" >&2
	exit 1
fi

ls -la "$GUEST_MNT"
# Convenience symlink (best-effort; Android may recreate /dev/socket)
if [ -d "/proc/$PID/root/dev/socket" ] || mkdir -p "/proc/$PID/root/dev/socket" 2>/dev/null; then
	ln -sfn "$GUESTDIR/host.sock" "/proc/$PID/root/dev/socket/waydroid_bt" 2>/dev/null || true
fi

echo "INJECT_OK pid=$PID socket=$GUESTDIR/host.sock"
