#!/bin/sh
# Wait for Waydroid container RUNNING + host.sock, then inject host BT socket directory.
# Safe to call from a user session autostart or after `waydroid session start`.
# Retries inject a few times (LXC mount races right after container start).
set -eu

INJECT="${INJECT_SCRIPT:-/usr/local/sbin/waydroid-bt-inject-socket.sh}"
LXC_PATH="${WAYDROID_LXC_PATH:-/var/lib/waydroid/lxc}"
HOSTDIR="${WAYDROID_BT_HOSTDIR:-/run/waydroid-bt}"
SOCK="$HOSTDIR/host.sock"
MAX_WAIT="${WAYDROID_BT_INJECT_WAIT:-90}"
INJECT_RETRIES="${WAYDROID_BT_INJECT_RETRIES:-5}"

if [ ! -x "$INJECT" ]; then
	echo "missing $INJECT" >&2
	exit 1
fi

# Ensure host daemon is at least attempted
if [ ! -S "$SOCK" ] && command -v systemctl >/dev/null 2>&1; then
	if [ "$(id -u)" -eq 0 ]; then
		systemctl start waydroid-bt-host 2>/dev/null || true
	else
		sudo systemctl start waydroid-bt-host 2>/dev/null || true
	fi
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
			if [ "$(id -u)" -eq 0 ]; then
				if "$INJECT"; then
					exit 0
				fi
			else
				if sudo "$INJECT"; then
					exit 0
				fi
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
