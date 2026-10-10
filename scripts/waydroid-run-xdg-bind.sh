#!/bin/sh
# Root helper: bind /run/user/<uid> onto /run/xdg (Waydroid's
# waydroid.xdg_runtime_dir) so the guest finds wayland-0 / pulse. Idempotent.
# Usage: waydroid-run-xdg-bind.sh UID
set -eu
uid="${1:-1000}"
src="/run/user/$uid"
dst="${WAYDROID_XDG_DIR:-/run/xdg}"

if [ "$(id -u)" -ne 0 ]; then
	echo "run as root (started by waydroid-run-xdg.service)" >&2
	exit 1
fi
case "$uid" in
'' | *[!0-9]*) echo "bad uid: $uid" >&2; exit 2 ;;
esac
if [ ! -d "$src" ]; then
	echo "SKIP: $src missing (user not logged in)"
	exit 0
fi
if [ -S "$dst/wayland-0" ]; then
	echo "XDG_BIND_OK already ($dst)"
	exit 0
fi
mkdir -p "$dst"
if mountpoint -q "$dst" 2>/dev/null; then
	umount "$dst" 2>/dev/null || umount -l "$dst" 2>/dev/null || true
fi
mount --bind "$src" "$dst"
echo "XDG_BIND_OK $src -> $dst"
