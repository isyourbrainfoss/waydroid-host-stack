#!/bin/sh
# Selftest: whs_waydroid_uid order (waydroid.prop > WAYDROID_UID > SUDO_UID >
# DOAS_USER > session/logind) and that root (0) is never picked.
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
u() { env -u SUDO_UID -u DOAS_USER -u WAYDROID_UID WAYDROID_PROP="$T/none" "$@" sh -c ". '$ROOT/scripts/lib/paths.sh'; whs_waydroid_uid" 2>/dev/null; }
check() {
	if [ "$2" = "$3" ]; then echo "ok $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi
}
echo "waydroid.host.uid=4242" >"$T/prop"
check "waydroid.prop wins" "$(u WAYDROID_PROP="$T/prop" SUDO_UID=60434)" 4242
printf 'waydroid.active_apps=Waydroid\n' >"$T/noprop"
check "SUDO_UID when prop has no host.uid" "$(u WAYDROID_PROP="$T/noprop" SUDO_UID=60434)" 60434
check "WAYDROID_UID before SUDO_UID" "$(u WAYDROID_UID=60500 SUDO_UID=60434)" 60500
r=$(u SUDO_UID=0)
[ "$r" != 0 ] && echo "ok SUDO_UID=0 ignored ($r)" || { echo "FAIL SUDO_UID=0 picked"; fail=1; }
[ "$fail" -eq 0 ] || { echo WAYDROID_UID_SELFTEST_FAILED; exit 1; }
echo ALL_WAYDROID_UID_SELFTESTS_OK
