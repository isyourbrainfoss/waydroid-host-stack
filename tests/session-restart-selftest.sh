#!/bin/sh
# Selftest: waydroid-bt-session-restart.sh with fake systemctl/getent/state.
set -u
ROOT="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
H="$ROOT/scripts/waydroid-bt-session-restart.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/systemctl" <<'F'
#!/bin/sh
echo "systemctl $*" >>"$FAKE_CALLS"
[ "${FAKE_HANG:-0}" = 1 ] && sleep 30
case "$*" in
*" restart "*) exit "${FAKE_RESTART_RC:-0}" ;;
"--user -M "*" show "*)
	[ "${FAKE_SESS_STATE:-}" = missing ] && exit 1
	echo "ActiveState=${FAKE_SESS_STATE:-inactive}"
	echo "ActiveEnterTimestampMonotonic=${FAKE_SESS_US:-0}" ;;
"show "*) echo "ExecMainStartTimestampMonotonic=${FAKE_BRIDGE_US:-0}" ;;
esac
exit 0
F
cat >"$T/bin/getent" <<'F'
#!/bin/sh
[ "$1 $2" = "passwd 60434" ] && echo "fp5:x:60434:60434::/home/fp5:/bin/sh" && exit 0
exit 2
F
chmod +x "$T/bin/systemctl" "$T/bin/getent"
fail=0
run() { # run NAME EXPECT_RESTART(0|1) [ENV...]
	name=$1 want=$2
	shift 2
	: >"$T/calls"
	out=$(env PATH="$T/bin:$PATH" FAKE_CALLS="$T/calls" WAYDROID_PROP="$T/none" \
		WHS_SESSION_RESTART_STATE="$T/state" "$@" sh "$H" 2>&1)
	rc=$?
	got=0
	grep -q -- "--user -M fp5@ restart --no-block waydroid-session.service" "$T/calls" && got=1
	if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then
		echo "ok $name: $out" | head -n2 | tr '\n' ' '; echo
	else
		echo "FAIL $name rc=$rc restart=$got want=$want: $out"
		fail=1
	fi
}
rm -f "$T/state"
run "boot (session not up yet)" 0 WHS_USER=fp5 FAKE_BRIDGE_US=5000000 FAKE_SESS_STATE=inactive
run "session unit missing" 0 WHS_USER=fp5 FAKE_BRIDGE_US=5000000 FAKE_SESS_STATE=missing
run "session started after bridge" 0 WHS_USER=fp5 FAKE_BRIDGE_US=5000000 FAKE_SESS_STATE=active FAKE_SESS_US=9000000
run "bridge restart, session running" 1 WHS_USER=fp5 FAKE_BRIDGE_US=900000000 FAKE_SESS_STATE=active FAKE_SESS_US=9000000
[ -s "$T/state" ] || { echo "FAIL state not written"; fail=1; }
run "debounce (second restart within 60s)" 0 WHS_USER=fp5 FAKE_BRIDGE_US=910000000 FAKE_SESS_STATE=active FAKE_SESS_US=9000000
echo $(($(date +%s) - 120)) >"$T/state"
run "after debounce window, user via WAYDROID_UID" 1 WAYDROID_UID=60434 FAKE_BRIDGE_US=920000000 FAKE_SESS_STATE=active FAKE_SESS_US=9000000
rm -f "$T/state"
run "restart command fails -> still exit 0" 1 WHS_USER=fp5 FAKE_RESTART_RC=1 FAKE_BRIDGE_US=900000000 FAKE_SESS_STATE=active FAKE_SESS_US=9000000
printf '%s' "$out" | grep -q "warn: restart of waydroid-session.service failed" || { echo "FAIL no warn on failed restart"; fail=1; }
rm -f "$T/state"
run "disabled" 0 WHS_USER=fp5 WHS_SESSION_RESTART=0 FAKE_BRIDGE_US=900000000 FAKE_SESS_STATE=active FAKE_SESS_US=9000000
rm -f "$T/state"
s=$(date +%s)
run "systemctl hangs -> timeout, exit 0" 0 WHS_USER=fp5 FAKE_HANG=1 WHS_SESSION_RESTART_TIMEOUT=1 FAKE_BRIDGE_US=900000000 FAKE_SESS_STATE=active FAKE_SESS_US=9000000
[ $(($(date +%s) - s)) -lt 10 ] || { echo "FAIL hang not bounded"; fail=1; }
run "no user resolvable" 0 WAYDROID_UID=70000 FAKE_SESS_STATE=active
# pure decision table
d() { sh "$H" --decide "$@"; }
[ "$(d 5 active 4 0 100 60)" = restart ] || { echo "FAIL decide restart"; fail=1; }
[ "$(d 5 active 5 0 100 60)" = skip:session-started-after-bridge ] || { echo "FAIL decide equal"; fail=1; }
[ "$(d 0 active 4 0 100 60)" = skip:bridge-start-unknown ] || { echo "FAIL decide bridge0"; fail=1; }
[ "$(d 5 activating 4 0 100 60)" = "skip:session-not-active(activating)" ] || { echo "FAIL decide activating"; fail=1; }
[ "$fail" -eq 0 ] || { echo SESSION_RESTART_SELFTEST_FAILED; exit 1; }
echo ALL_SESSION_RESTART_SELFTESTS_OK
