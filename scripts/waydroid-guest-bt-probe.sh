#!/bin/sh
# Run Ping+GetAdapterInfo from *inside* the Waydroid mount namespace.
# Stages a host musl binary + loader/libs into the guest rootfs and runs it via
# lxc-attach (ships with Waydroid's LXC). nsenter is only a fallback, so hosts
# without util-linux nsenter (e.g. Nura/Duranium) work.
#
# Usage (on phone, root):
#   sudo waydroid-guest-bt-probe.sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
LIBDIR="${WHS_LIBDIR:-$SCRIPT_DIR/lib}"
[ -d "$LIBDIR" ] || LIBDIR="${PREFIX:-/var/lib/waydroid-host-stack}/lib"
# shellcheck source=scripts/lib/paths.sh
. "$LIBDIR/paths.sh"
whs_resolve_paths
PROBE_BIN="${1:-$LIBEXECDIR/waydroid-bt-guest-probe}"
INJECT="${INJECT_SCRIPT:-$(whs_find_helper waydroid-bt-inject-socket || echo "$SBINDIR/waydroid-bt-inject-socket.sh")}"
SOCK_IN_GUEST="${WAYDROID_BT_GUEST_SOCK:-/run/waydroid-bt/host.sock}"
LXC_PATH="${WAYDROID_LXC_PATH:-/var/lib/waydroid/lxc}"
STAGE_DIR="/data/local/tmp/waydroid-bt"

if [ "$(id -u)" -ne 0 ]; then
	echo "run as root (sudo $0)" >&2
	exit 1
fi

if [ ! -x "$PROBE_BIN" ]; then
	echo "missing probe binary: $PROBE_BIN" >&2
	exit 1
fi

if [ -x "$INJECT" ]; then
	"$INJECT"
else
	echo "missing inject script: $INJECT" >&2
	exit 1
fi

PID=$(lxc-info -P "$LXC_PATH" -n waydroid -pH 2>/dev/null || true)
if [ -z "${PID:-}" ] || [ "$PID" = "-1" ]; then
	echo "container not running after inject" >&2
	exit 1
fi

mkdir -p "/proc/$PID/root$STAGE_DIR"
cp -f "$PROBE_BIN" "/proc/$PID/root$STAGE_DIR/waydroid-bt-guest-probe"
chmod 755 "/proc/$PID/root$STAGE_DIR/waydroid-bt-guest-probe"

# Static musl binaries run directly; dynamic ones need the host musl loader + libs.
STATIC=0
# No `file` dependency: a static ELF has no PT_INTERP / .interp section.
if command -v readelf >/dev/null 2>&1; then
	readelf -l "$PROBE_BIN" 2>/dev/null | grep -q 'INTERP' || STATIC=1
elif ! grep -q 'ld-musl\|ld-linux' "$PROBE_BIN" 2>/dev/null; then
	STATIC=1
fi

LOADER=""
if [ "$STATIC" -eq 0 ]; then
	for cand in /lib/ld-musl-aarch64.so.1 /lib/ld-musl-x86_64.so.1; do
		if [ -e "$cand" ]; then
			LOADER=$(basename "$cand")
			cp -f "$cand" "/proc/$PID/root$STAGE_DIR/$LOADER"
			break
		fi
	done
	if [ -z "$LOADER" ]; then
		echo "could not find musl dynamic loader on host" >&2
		exit 1
	fi
	ldd "$PROBE_BIN" 2>/dev/null | while read -r line; do
		path=$(echo "$line" | awk '{
      for (i=1;i<=NF;i++) if ($i ~ /^\//) { print $i; exit }
    }')
		if [ -n "$path" ] && [ -e "$path" ]; then
			cp -f "$path" "/proc/$PID/root$STAGE_DIR/$(basename "$path")"
		fi
	done
fi

# Extra probe args via env, e.g. LE_SCAN_SECS=8 ALLOW_ZERO_ADS=1
# GATT: GATT_ADDRESS=AA:BB:... GATT_CHAR_UUID=... GATT_ALLOW_CONNECT_FAIL=1
EXTRA=""
if [ -n "${LE_SCAN_SECS:-}" ] && [ "$LE_SCAN_SECS" -gt 0 ] 2>/dev/null; then
	EXTRA="$EXTRA --le-scan-secs $LE_SCAN_SECS"
fi
if [ "${ALLOW_ZERO_ADS:-0}" = "1" ]; then
	EXTRA="$EXTRA --allow-zero-ads"
fi
if [ -n "${GATT_ADDRESS:-}" ]; then
	EXTRA="$EXTRA --gatt-address $GATT_ADDRESS"
fi
if [ -n "${GATT_CHAR_UUID:-}" ]; then
	EXTRA="$EXTRA --gatt-char-uuid $GATT_CHAR_UUID"
fi
if [ -n "${GATT_SERVICE_UUID:-}" ]; then
	EXTRA="$EXTRA --gatt-service-uuid $GATT_SERVICE_UUID"
fi
if [ -n "${GATT_TIMEOUT_MS:-}" ]; then
	EXTRA="$EXTRA --gatt-timeout-ms $GATT_TIMEOUT_MS"
fi
if [ "${GATT_ALLOW_CONNECT_FAIL:-0}" = "1" ]; then
	EXTRA="$EXTRA --gatt-allow-connect-fail"
fi
if [ -n "${GATT_NOTIFY_SECS:-}" ]; then
	EXTRA="$EXTRA --gatt-notify-secs $GATT_NOTIFY_SECS"
fi
if [ "${GATT_RECONNECT:-0}" = "1" ]; then
	EXTRA="$EXTRA --gatt-reconnect"
fi
if [ "${GATT_NO_RECONNECT:-0}" = "1" ]; then
	EXTRA="$EXTRA --gatt-no-reconnect"
fi

# Run a command inside the container: lxc-attach first, nsenter -m fallback.
run_in_guest() {
	if command -v lxc-attach >/dev/null 2>&1; then
		lxc-attach -P "$LXC_PATH" -n waydroid --clear-env -- "$@"
	elif command -v nsenter >/dev/null 2>&1; then
		nsenter -t "$PID" -m -- "$@"
	else
		echo "need lxc-attach or nsenter" >&2
		return 1
	fi
}

echo "=== guest probe (container pid=$PID static=$STATIC) ==="
# shellcheck disable=SC2086
if [ "$STATIC" -eq 1 ]; then
	run_in_guest \
		"$STAGE_DIR/waydroid-bt-guest-probe" \
		--socket "$SOCK_IN_GUEST" \
		--client-name "guest-ns-probe" \
		$EXTRA
else
	run_in_guest \
		"$STAGE_DIR/$LOADER" \
		--library-path "$STAGE_DIR" \
		"$STAGE_DIR/waydroid-bt-guest-probe" \
		--socket "$SOCK_IN_GUEST" \
		--client-name "guest-ns-probe" \
		$EXTRA
fi
