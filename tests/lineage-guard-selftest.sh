#!/bin/sh
# Selftest: system.img location (WAYDROID_SYSTEM_IMG > waydroid.cfg images_path
# > /var/lib/waydroid/images) used by the version guard and stabilize step.
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
img() { env -u WAYDROID_SYSTEM_IMG "$@" sh -c ". '$ROOT/scripts/lib/lineage-guard.sh'; echo \"\$WAYDROID_SYSTEM_IMG\""; }
check() {
	if [ "$2" = "$3" ]; then echo "ok $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi
}
mkdir -p "$T/images"
: >"$T/images/system.img"
printf '[waydroid]\narch = arm64\nimages_path = %s  \n\n[properties]\nimages_path = /wrong\n' "$T/images" >"$T/waydroid.cfg"
check "images_path from waydroid.cfg" "$(img WAYDROID_CFG="$T/waydroid.cfg")" "$T/images/system.img"
check "WAYDROID_SYSTEM_IMG override" "$(img WAYDROID_CFG="$T/waydroid.cfg" WAYDROID_SYSTEM_IMG=/x/system.img)" /x/system.img
check "no cfg -> legacy path" "$(img WAYDROID_CFG="$T/missing.cfg")" /var/lib/waydroid/images/system.img
printf '[waydroid]\narch = arm64\n' >"$T/noimg.cfg"
check "cfg without images_path -> legacy path" "$(img WAYDROID_CFG="$T/noimg.cfg")" /var/lib/waydroid/images/system.img
[ "$fail" -eq 0 ] || { echo LINEAGE_GUARD_SELFTEST_FAILED; exit 1; }
echo ALL_LINEAGE_GUARD_SELFTESTS_OK
