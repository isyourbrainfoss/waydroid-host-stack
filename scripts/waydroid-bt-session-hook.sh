#!/bin/sh
# Wait for Waydroid container RUNNING + host.sock, then inject host BT socket directory.
# Root-only: runs from waydroid-bt-inject.service (timer). When called as a
# normal user it just asks systemd to run that unit (no sudo prompts).
# Retries inject a few times (LXC mount races right after container start).
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
LIBDIR="${WHS_LIBDIR:-$SCRIPT_DIR/lib}"
[ -d "$LIBDIR" ] || LIBDIR="${PREFIX:-/var/lib/waydroid-host-stack}/lib"
# shellcheck source=scripts/lib/paths.sh
. "$LIBDIR/paths.sh"
whs_resolve_paths
INJECT="${INJECT_SCRIPT:-$(whs_find_helper waydroid-bt-inject-socket || echo "$SBINDIR/waydroid-bt-inject-socket.sh")}"
LXC_PATH="${WAYDROID_LXC_PATH:-/var/lib/waydroid/lxc}"
HOSTDIR="${WAYDROID_BT_HOSTDIR:-/run/waydroid-bt}"
SOCK="$HOSTDIR/host.sock"
# Keep short: a timer must not leave multi-minute waiters stacked.
MAX_WAIT="${WAYDROID_BT_INJECT_WAIT:-15}"
INJECT_RETRIES="${WAYDROID_BT_INJECT_RETRIES:-3}"

if [ "$(id -u)" -ne 0 ]; then
	exec systemctl start --no-ask-password waydroid-bt-inject.service
fi

if [ ! -x "$INJECT" ]; then
	echo "missing $INJECT" >&2
	exit 1
fi

# Fast path: container not running → success (nothing to inject). Avoids
# thrashing every timer tick when Waydroid is stopped.
PID=$(lxc-info -P "$LXC_PATH" -n waydroid -pH 2>/dev/null || true)
if [ -z "${PID:-}" ] || [ "$PID" = "-1" ] || ! [ "$PID" -gt 1 ] 2>/dev/null; then
	echo "SKIP_INJECT: waydroid LXC not running"
	exit 0
fi

# Ensure host daemon is at least attempted
if [ ! -S "$SOCK" ] && command -v systemctl >/dev/null 2>&1; then
	systemctl start waydroid-bt-host 2>/dev/null || true
fi

i=0
while [ "$i" -lt "$MAX_WAIT" ]; do
	PID=$(lxc-info -P "$LXC_PATH" -n waydroid -pH 2>/dev/null || true)
	if [ -n "${PID:-}" ] && [ "$PID" != "-1" ] && [ "$PID" -gt 1 ] 2>/dev/null; then
		# Socket may appear slightly after container pid
		if [ ! -S "$SOCK" ]; then
			i=$((i + 1))
			sleep 1
			continue
		fi
		r=0
		while [ "$r" -lt "$INJECT_RETRIES" ]; do
			if "$INJECT"; then
				exit 0
			fi
			r=$((r + 1))
			sleep 1
		done
		echo "inject failed after $INJECT_RETRIES retries (pid=$PID)" >&2
		exit 1
	fi
	i=$((i + 1))
	sleep 1
done

echo "timeout waiting for waydroid LXC pid (${MAX_WAIT}s)" >&2
exit 1
