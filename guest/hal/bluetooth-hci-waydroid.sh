#!/system/bin/sh
# Soft HCI HAL launcher for Waydroid init (oneshot-safe, single instance).
#
# hwservicemanager.ready and sys.boot_completed both start this oneshot.
# Use a flock so concurrent starts never spawn a second HAL process.
export LD_LIBRARY_PATH=/system/lib64:/system/lib${LD_LIBRARY_PATH:+:}$LD_LIBRARY_PATH
HAL=/system/bin/hw/android.hardware.bluetooth@1.0-service.waydroid
LOCKDIR=/data/local/tmp/waydroid-bt
LOCK=$LOCKDIR/soft-hci.lock
PIDFILE=$LOCKDIR/soft-hci.pid

mkdir -p "$LOCKDIR" 2>/dev/null || true

# Fast path: already running (pidof / ps)
if /system/bin/pidof android.hardware.bluetooth@1.0-service.waydroid >/dev/null 2>&1; then
	exit 0
fi
if /system/bin/ps -A 2>/dev/null | /system/bin/grep -q '[a]ndroid.hardware.bluetooth@1.0-service.waydroid'; then
	exit 0
fi
# Stale pidfile: only treat as live if pid still maps to our HAL
if [ -f "$PIDFILE" ]; then
	old=$(cat "$PIDFILE" 2>/dev/null || true)
	if [ -n "$old" ] && [ -d "/proc/$old" ]; then
		# cmdline may be truncated; basename match is enough
		if /system/bin/tr '\0' ' ' <"/proc/$old/cmdline" 2>/dev/null | /system/bin/grep -q 'android.hardware.bluetooth@1.0-service.waydroid'; then
			exit 0
		fi
	fi
	rm -f "$PIDFILE" 2>/dev/null || true
fi

# Background HAL (pidof above avoids most races; avoid flock -c — not portable
# on all guest toybox/busybox builds and broke Soft HCI auto-start).
$HAL >/dev/null 2>&1 &
echo $! >"$PIDFILE" 2>/dev/null || true
exit 0
