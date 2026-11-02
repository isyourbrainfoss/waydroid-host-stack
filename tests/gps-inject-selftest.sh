#!/bin/sh
# Selftest for waydroid-gps-inject.sh: test providers are created as soon as
# Android has booted, before any host fix exists. Fakes lxc-info/lxc-attach.
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/lxc-info" <<'F'
#!/bin/sh
case "$*" in
*-pH*) cat "$FAKE/pid" ;;
*-sH*) cat "$FAKE/cstate" ;;
esac
F
cat >"$T/bin/lxc-attach" <<'F'
#!/bin/sh
for a; do s=$a; done
echo "$s" >>"$FAKE/attach.log"
case "$s" in
*sys.boot_completed*) cat "$FAKE/booted" ;;
*add-test-provider*) echo GPS_SETUP_OK ;;
*set-test-provider-location*) echo GPS_INJECT_RC=0 ;;
esac
F
chmod +x "$T/bin/"*
FAKE=$T
export FAKE
PATH="$T/bin:$PATH"
export WAYDROID_GPS_FIX="$T/no-fix" WAYDROID_GPS_STATE="$T/inject"
S="$ROOT/scripts/waydroid-gps-inject.sh"
fail=0
ok() { echo "ok $*"; }
bad() { echo "FAIL $*"; fail=1; }

echo 4242 >"$T/pid"
echo RUNNING >"$T/cstate"
echo 0 >"$T/booted"
if sh "$S" setup >/dev/null 2>&1; then bad "setup before boot_completed"; else ok "no setup before boot"; fi
echo 1 >"$T/booted"
out=$(sh "$S" setup 2>&1) || true
case "$out" in *GPS_SETUP_OK*) ok "setup without host fix" ;; *) bad "setup without host fix: $out" ;; esac
[ "$(cat "$T/inject/setup-pid")" = 4242 ] && ok "setup-pid recorded" || bad "setup-pid"
n=$(grep -c add-test-provider "$T/attach.log")
sh "$S" setup >/dev/null 2>&1 || bad "second setup"
[ "$(grep -c add-test-provider "$T/attach.log")" = "$n" ] && ok "setup once per boot" || bad "setup repeated"
echo FROZEN >"$T/cstate"
if sh "$S" setup >/dev/null 2>&1; then bad "setup while frozen"; else ok "frozen skipped"; fi
echo RUNNING >"$T/cstate"
echo 5151 >"$T/pid"
sh "$S" setup >/dev/null 2>&1 && [ "$(cat "$T/inject/setup-pid")" = 5151 ] && ok "re-setup after container restart" || bad "re-setup"
echo "59.9|10.7|12|||||test" >"$T/fix"
out=$(WAYDROID_GPS_FIX="$T/fix" sh "$S" once 2>&1) || true
case "$out" in *GPS_INJECT_OK*) ok "inject with fix" ;; *) bad "inject: $out" ;; esac
[ "$fail" -eq 0 ] || { echo GPS_INJECT_SELFTEST_FAILED; exit 1; }
echo ALL_GPS_INJECT_SELFTESTS_OK
