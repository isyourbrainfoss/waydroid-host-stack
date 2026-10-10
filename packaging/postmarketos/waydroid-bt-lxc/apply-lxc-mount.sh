#!/bin/sh
# Ensure Waydroid's LXC config includes the waydroid-bt mount fragment.
#
# Waydroid regenerates lxc/waydroid/config on `waydroid init` / upgrades and
# config_nodes on (re)init, so appending mount lines there is lost. Instead we
# keep the fragment in $SYSCONFDIR/lxc-mount.conf and add a single
#   lxc.include = /etc/waydroid-bt/lxc-mount.conf
# at the END of `config`, i.e. after the config_nodes include (which mounts a
# tmpfs on /run). Our rbind must come after that tmpfs or it would be hidden.
#
# Idempotent; safe from ExecStartPre / path units. Exit 0 if Waydroid is not
# initialised yet.
set -eu

FRAGMENT="${WAYDROID_BT_FRAGMENT:-/etc/waydroid-bt/lxc-mount.conf}"
LXC_DIR="${WAYDROID_LXC_DIR:-/var/lib/waydroid/lxc/waydroid}"
CONFIG="$LXC_DIR/config"
LINE="lxc.include = $FRAGMENT"

if [ "$(id -u)" -ne 0 ]; then
	echo "run as root" >&2
	exit 1
fi
if [ ! -f "$FRAGMENT" ]; then
	echo "missing fragment: $FRAGMENT" >&2
	exit 1
fi
mkdir -p /run/waydroid-bt
if [ ! -f "$CONFIG" ]; then
	echo "SKIP: $CONFIG not found (run waydroid init first)"
	exit 0
fi

# Drop legacy appended mount lines from config_nodes (old installer) so the
# mount is not applied twice.
if [ -f "$LXC_DIR/config_nodes" ] && grep -q 'waydroid-bt' "$LXC_DIR/config_nodes"; then
	tmp="$LXC_DIR/.config_nodes.whs.$$"
	grep -v 'waydroid-bt' "$LXC_DIR/config_nodes" >"$tmp" || true
	cat "$tmp" >"$LXC_DIR/config_nodes"
	rm -f "$tmp"
	echo "removed legacy waydroid-bt entry from config_nodes"
fi

last=$(grep -n '^lxc.include' "$CONFIG" | tail -n1 | cut -d: -f2- || true)
if [ "$last" = "$LINE" ]; then
	echo "LXC_INCLUDE_OK already last include in $CONFIG"
	exit 0
fi

# Present but not last (Waydroid added includes after it): move it to the end.
tmp="$LXC_DIR/.config.whs.$$"
grep -vxF "$LINE" "$CONFIG" >"$tmp" || true
printf '%s\n' "$LINE" >>"$tmp"
cat "$tmp" >"$CONFIG"
rm -f "$tmp"
echo "LXC_INCLUDE_OK appended to $CONFIG (restart waydroid-container to apply)"
