#!/bin/sh
# Selftest: waydroid-bt-attach-watchdog.sh decision table + a fake-systemctl run.
set -u
# User+mount namespace so we can create /run/user/UID/bus for the home-guard gate
# without touching the host or the scripts under test.
if [ "${WHS_TEST_NS:-}" != 1 ]; then
	exec unshare --user --map-root-user --mount env WHS_TEST_NS=1 /bin/sh "$0" "$@"
fi
mount --make-rprivate / >/dev/null 2>&1 || true
mount -t tmpfs tmpfs /run
mkdir -p /run/user/60434
python3 -c 'import socket; s=socket.socket(socket.AF_UNIX); s.bind("/run/user/60434/bus")'
ROOT="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
H="$ROOT/scripts/waydroid-bt-attach-watchdog.sh"
fail=0
dec() { # dec WANT ARGS...
	want=$1
	shift
	got=$(sh "$H" --decide "$@")
	case "$got" in
	"$want"*) echo "ok decide: $got" ;;
	*) echo "FAIL decide: want $want got $got (args: $*)"; fail=1 ;;
	esac
}
N=100000
# st age ka ever changed strike last count now dmin rate maxb minage
dec ok:session-not-active inactive 999 0 1 1000 0 0 0 $N 60 1800 6 180
dec ok:session-young active 30 0 1 1000 0 0 0 $N 60 1800 6 180
dec ok:no-bridge-status active 999 "" 0 0 0 0 0 $N 60 1800 6 180
dec ok:attached active 999 1 1 1000 0 0 0 $N 60 1800 6 180
dec ok:hal-never-attached active 999 0 0 1000 0 0 0 $N 60 1800 6 180
dec ok:detached-only active 999 0 1 $((N - 20)) 0 0 0 $N 60 1800 6 180
dec strike active 999 0 1 $((N - 120)) 0 0 0 $N 60 1800 6 180
dec ok:second-look-too-soon active 999 0 1 $((N - 120)) $((N - 30)) 0 0 $N 60 1800 6 180
dec restart active 999 0 1 $((N - 400)) $((N - 180)) 0 0 $N 60 1800 6 180
dec ok:rate-limited active 999 0 1 $((N - 400)) $((N - 180)) $((N - 600)) 1 $N 60 1800 6 180
dec ok:max-per-boot active 999 0 1 $((N - 400)) $((N - 180)) $((N - 4000)) 6 $N 60 1800 6 180

# End-to-end with fake systemctl: first run = strike, second = restart, third = rate-limited.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"
cat >"$T/bin/systemctl" <<'F'
#!/bin/sh
echo "systemctl $*" >>"$FAKE_CALLS"
case "$*" in
"is-active -q user@"*)
	[ "${FAKE_USER_MANAGER:-1}" = 1 ] && exit 0
	exit 3 ;;
*" restart "*) exit 0 ;;
"--user -M "*" show "*)
	echo "ActiveState=active"
	echo "ActiveEnterTimestamp=@$FAKE_SESS_ENTER" ;;
esac
exit 0
F
cat >"$T/bin/id" <<'F'
#!/bin/sh
[ "$1" = "-u" ] && { echo "${FAKE_ID_UID:-60434}"; exit 0; }
exit 1
F
chmod +x "$T/bin/systemctl" "$T/bin/id"
now=$(date +%s)
printf 'keepalive=0\never=1\nchanged=%s\n' $((now - 300)) >"$T/status"
: >"$T/calls"
run() {
	env PATH="$T/bin:$PATH" FAKE_CALLS="$T/calls" FAKE_SESS_ENTER=$((now - 3600)) WHS_USER=fp5 \
		WHS_BRIDGE_STATUS="$T/status" WHS_ATTACH_STATE_DIR="$T/state" WHS_ATTACH_DETACH_MIN=0 sh "$H"
}
o1=$(run)
r1=$(grep -c " restart " "$T/calls")
o2=$(run)
r2=$(grep -c " restart " "$T/calls")
o3=$(run)
r3=$(grep -c " restart " "$T/calls")
if [ "$r1" = 0 ] && [ "$r2" = 1 ] && [ "$r3" = 1 ] && grep -q -- "--user -M fp5@ restart --no-block waydroid-session.service" "$T/calls"; then
	echo "ok e2e: strike -> restart -> rate-limited"
else
	echo "FAIL e2e: r1=$r1 r2=$r2 r3=$r3 / $o1 / $o2 / $o3"
	fail=1
fi
# Attached again: no restart, strike cleared, quiet.
printf 'keepalive=1\never=1\nchanged=%s\n' "$now" >"$T/status"
o4=$(run)
[ ! -f "$T/state/strike" ] && [ "$(grep -c " restart " "$T/calls")" = 1 ] && echo "ok e2e attached: $o4" || { echo "FAIL attached: $o4"; fail=1; }
o5=$(run)
[ -z "$o5" ] && echo "ok e2e quiet when healthy" || { echo "FAIL not quiet: $o5"; fail=1; }
# Disabled
o6=$(WHS_ATTACH_WATCHDOG=0 sh "$H")
case "$o6" in *disabled*) echo "ok disabled" ;; *) echo "FAIL disabled: $o6"; fail=1 ;; esac
# Home-guard: skip when the user manager is not running.
o7=$(FAKE_USER_MANAGER=0 run)
case "$o7" in *'fp5 home-guard'*) echo "ok home-guard skip" ;; *) echo "FAIL home-guard: $o7"; fail=1 ;; esac

[ "$fail" -eq 0 ] && echo ATTACH_WATCHDOG_SELFTEST_OK || { echo ATTACH_WATCHDOG_SELFTEST_FAILED; exit 1; }
