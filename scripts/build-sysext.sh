#!/bin/sh
# Build a systemd-sysext extension with the host side of waydroid-host-stack.
#
#   sh scripts/build-sysext.sh [--out DIR] [--id ID] [--level LEVEL] [--format dir|squashfs|erofs]
#
# Output: $OUT/waydroid-host-stack.raw (squashfs/erofs) or $OUT/waydroid-host-stack/ (dir).
# Install on the phone:
#   sudo sh scripts/install-host-system.sh --sysext waydroid-host-stack.raw
# which copies it to /var/lib/extensions/ and runs `systemd-sysext refresh`.
#
# extension-release defaults to ID=_any (works across OS versions). Pass
# --id nura --level 26100602 to pin it to one image build (must match
# SYSEXT_LEVEL in /etc/os-release, so it must be rebuilt after every OTA).
#
# Caveat: hosts that enforce signed/verity sysext images (image policy) will
# reject an unsigned extension; fall back to `install-host-system.sh`
# (PREFIX=/var/lib/waydroid-host-stack) in that case.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out"
ID="_any"
LEVEL=""
FORMAT=""
NAME=waydroid-host-stack
while [ $# -gt 0 ]; do
	case "$1" in
	--out) shift; OUT="$1" ;;
	--id) shift; ID="$1" ;;
	--level) shift; LEVEL="$1" ;;
	--format) shift; FORMAT="$1" ;;
	--bin-dir) shift; export BIN_DIR_ARG="$1" ;;
	-h | --help) sed -n '2,20p' "$0"; exit 0 ;;
	*) echo "unknown arg: $1" >&2; exit 2 ;;
	esac
	shift
done
if [ -z "$FORMAT" ]; then
	if command -v mksquashfs >/dev/null 2>&1; then FORMAT=squashfs
	elif command -v mkfs.erofs >/dev/null 2>&1; then FORMAT=erofs
	else FORMAT=dir
	fi
fi

TREE="$OUT/$NAME"
rm -rf "$TREE"
mkdir -p "$TREE"

set --
[ -n "${BIN_DIR_ARG:-}" ] && set -- --bin-dir "$BIN_DIR_ARG"
DESTDIR="$TREE" FORCE_IMMUTABLE=0 PREFIX=/usr BINDIR=/usr/bin \
	SBINDIR=/usr/libexec/waydroid-host-stack LIBEXECDIR=/usr/libexec/waydroid-host-stack \
	UNITDIR=/usr/lib/systemd/system SYSCONFDIR=/usr/share/waydroid-host-stack \
	sh "$ROOT/scripts/install-host-system.sh" --stage-only "$@"

# /etc is not part of a sysext; keep the fragment under /usr/share for reference
# (install-host-system.sh --sysext installs the live copy into /etc/waydroid-bt).
rel="$TREE/usr/lib/extension-release.d/extension-release.$NAME"
mkdir -p "$(dirname "$rel")"
{
	echo "ID=$ID"
	[ -n "$LEVEL" ] && echo "SYSEXT_LEVEL=$LEVEL"
	echo "ARCHITECTURE=arm64"
} >"$rel"

case "$FORMAT" in
dir) echo "SYSEXT_DIR $TREE" ;;
squashfs)
	rm -f "$OUT/$NAME.raw"
	mksquashfs "$TREE" "$OUT/$NAME.raw" -all-root -noappend -quiet
	echo "SYSEXT_RAW $OUT/$NAME.raw"
	;;
erofs)
	rm -f "$OUT/$NAME.raw"
	mkfs.erofs --all-root "$OUT/$NAME.raw" "$TREE" >/dev/null
	echo "SYSEXT_RAW $OUT/$NAME.raw"
	;;
*) echo "bad format: $FORMAT" >&2; exit 2 ;;
esac
