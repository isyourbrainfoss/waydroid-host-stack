# shellcheck shell=sh
# Shared guest helpers (root). Waydroid FREEZES the container (cgroup freezer)
# when the session is idle/screen off; lxc-attach into a frozen container
# blocks forever. Always check state first and bound every attach.
WHS_LXC_PATH="${WAYDROID_LXC_PATH:-/var/lib/waydroid/lxc}"

whs_container_state() {
	lxc-info -P "$WHS_LXC_PATH" -n waydroid -sH 2>/dev/null | tr -d '[:space:]'
}

# Unfreeze if frozen (for root maintenance steps). Returns 0 when RUNNING.
whs_container_thaw() {
	st=$(whs_container_state)
	if [ "$st" = FROZEN ]; then
		echo "container FROZEN — unfreezing" >&2
		lxc-unfreeze -P "$WHS_LXC_PATH" -n waydroid 2>&1 || true
		sleep 1
		st=$(whs_container_state)
	fi
	[ "$st" = RUNNING ]
}

# gsh SCRIPT [TIMEOUT_S] — run /system/bin/sh -c SCRIPT in the guest as root.
# stdin from /dev/null so lxc-attach never allocates a pty or waits on input.
gsh() {
	if [ "${WHS_AUTO_THAW:-0}" = 1 ] && [ "$(whs_container_state)" = FROZEN ]; then
		whs_container_thaw || true
	fi
	timeout -k 3 "${2:-25}" lxc-attach -P "$WHS_LXC_PATH" -n waydroid --clear-env \
		-v PATH=/product/bin:/apex/com.android.runtime/bin:/system/bin:/system/xbin:/vendor/bin \
		-v ANDROID_ROOT=/system -v ANDROID_DATA=/data -v HOME=/data \
		-- /system/bin/sh -c "$1" </dev/null 2>&1
	rc=$?
	[ "$rc" = 124 ] && echo "GSH_TIMEOUT(${2:-25}s): $1" | cut -c1-120 >&2
	return "$rc"
}
