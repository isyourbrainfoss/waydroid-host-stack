#!/bin/sh
# Append waydroid-bt socket mount to Waydroid LXC config if not present.
set -eu

FRAGMENT="${WAYDROID_BT_FRAGMENT:-/etc/waydroid-bt/lxc-mount.conf}"
# Common Waydroid locations (first existing parent wins for write target)
CANDIDATES="
/var/lib/waydroid/lxc/waydroid/config_nodes
/var/lib/waydroid/lxc/waydroid/config
"

if [ ! -f "$FRAGMENT" ]; then
	echo "missing fragment: $FRAGMENT" >&2
	exit 1
fi

LINE=$(grep -v '^#' "$FRAGMENT" | grep -v '^$' | head -n1)
if [ -z "$LINE" ]; then
	echo "empty fragment" >&2
	exit 1
fi

for dest in $CANDIDATES; do
	dir=$(dirname "$dest")
	if [ -d "$dir" ]; then
		if [ -f "$dest" ] && grep -q 'waydroid_bt' "$dest" 2>/dev/null; then
			echo "already configured: $dest"
			exit 0
		fi
		echo "$LINE" >>"$dest"
		echo "appended mount to $dest"
		echo "restart waydroid-container / waydroid session for changes to apply"
		exit 0
	fi
done

echo "Waydroid LXC config not found; install waydroid and re-run" >&2
echo "fragment kept at $FRAGMENT" >&2
exit 1
