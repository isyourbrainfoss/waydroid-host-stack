#!/bin/sh
# Safety net for the guest Bluetooth HAL attachment (runs as root from
# waydroid-bt-attach-watchdog.timer, every few minutes and after resume).
#
# The Soft HCI HAL keeps one ping-only "keepalive" connection to the host
# bridge for its whole lifetime; the bridge writes /run/waydroid-bt/bridge-status
# (keepalive=<n> ever=<0|1> changed=<unix s>). If the guest is detached while
# the Waydroid session is meant to run, restart the session user unit, so
# Android (and the Tesla app) comes back attached. Car absent is NOT a reason:
# a missing car never detaches the keepalive.
#
# Restart only if ALL hold:
#   * WHS_ATTACH_WATCHDOG is not 0
#   * the session user unit is active and has been for >= MIN_SESSION_AGE s
#   * bridge-status exists, ever=1 (this bridge saw the HAL attach), keepalive=0
#     and changed is >= DETACH_MIN s ago
#   * the previous check also saw "detached" (two strikes, >= DETACH_MIN s
#     apart), so a check right after resume never acts alone
#   * last restart by this helper >= RATE s ago, and < MAX_PER_BOOT this boot
# Fail-soft: always exits 0; every systemctl call is time-limited. Logs one line.
#
# Config (environment): WHS_USER, WAYDROID_UID (see lib/paths.sh),
#   WHS_SESSION_UNIT (default waydroid-session.service),
#   WHS_BRIDGE_STATUS (default /run/waydroid-bt/bridge-status),
#   WHS_ATTACH_STATE_DIR (default /run/waydroid-bt-watchdog),
#   WHS_ATTACH_DETACH_MIN (60), WHS_ATTACH_RATE (1800), WHS_ATTACH_MAX_PER_BOOT (6),
#   WHS_ATTACH_MIN_SESSION_AGE (180).
set -u

log() { echo "attach-watchdog: $*"; }

SESSION_UNIT="${WHS_SESSION_UNIT:-waydroid-session.service}"
STATUS="${WHS_BRIDGE_STATUS:-/run/waydroid-bt/bridge-status}"
SDIR="${WHS_ATTACH_STATE_DIR:-/run/waydroid-bt-watchdog}"
DETACH_MIN="${WHS_ATTACH_DETACH_MIN:-60}"
RATE="${WHS_ATTACH_RATE:-1800}"
MAXB="${WHS_ATTACH_MAX_PER_BOOT:-6}"
MIN_AGE="${WHS_ATTACH_MIN_SESSION_AGE:-180}"
TMO="${WHS_ATTACH_TIMEOUT:-10}"

num() { case "$1" in '' | *[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }
DETACH_MIN=$(num "$DETACH_MIN" 60)
RATE=$(num "$RATE" 1800)
MAXB=$(num "$MAXB" 6)
MIN_AGE=$(num "$MIN_AGE" 180)
TMO=$(num "$TMO" 10)

case "${WHS_ATTACH_WATCHDOG:-1}" in
0 | no | false | off) log "disabled (WHS_ATTACH_WATCHDOG=0)"; exit 0 ;;
esac

# whs_attach_decide SESS_STATE SESS_AGE KEEPALIVE EVER CHANGED STRIKE LAST COUNT NOW
#   DETACH_MIN RATE MAXB MIN_AGE
# -> "ok:<why>", "strike" (first detached sighting) or "restart". Pure; selftest.
whs_attach_decide() {
	st="$1" age="$2" ka="$3" ever="$4" ch="$5" strike="$6" last="$7" cnt="$8" now="$9"
	shift 9
	dmin="$1" rate="$2" maxb="$3" minage="$4"
	[ "$st" = active ] || { echo "ok:session-not-active($st)"; return 0; }
	age=$(num "$age" 0)
	[ "$age" -ge "$minage" ] || { echo "ok:session-young(${age}s)"; return 0; }
	case "$ka" in '' | *[!0-9]*) echo "ok:no-bridge-status"; return 0 ;; esac
	[ "$ka" -eq 0 ] || { echo "ok:attached"; return 0; }
	[ "$ever" = 1 ] || { echo "ok:hal-never-attached(old-hal-or-bt-off)"; return 0; }
	ch=$(num "$ch" 0)
	[ $((now - ch)) -ge "$dmin" ] || { echo "ok:detached-only-$((now - ch))s"; return 0; }
	strike=$(num "$strike" 0)
	if [ "$strike" -eq 0 ] || [ $((now - strike)) -lt "$dmin" ]; then
		[ "$strike" -eq 0 ] && { echo strike; return 0; }
		echo "ok:second-look-too-soon($((now - strike))s)"
		return 0
	fi
	last=$(num "$last" 0)
	cnt=$(num "$cnt" 0)
	if [ "$last" -gt 0 ] && [ $((now - last)) -lt "$rate" ]; then
		echo "ok:rate-limited($((now - last))s<${rate}s)"
		return 0
	fi
	[ "$cnt" -lt "$maxb" ] || { echo "ok:max-per-boot($cnt)"; return 0; }
	echo restart
}

[ "${1:-}" = --decide ] && { shift; whs_attach_decide "$@"; exit 0; }

t() {
	if command -v timeout >/dev/null 2>&1; then timeout "$TMO" "$@"; else "$@"; fi
}

U="${WHS_USER:-}"
if [ -z "$U" ]; then
	SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
	LIBDIR="${WHS_LIBDIR:-$SCRIPT_DIR/lib}"
	if [ -f "$LIBDIR/paths.sh" ]; then
		# shellcheck source=scripts/lib/paths.sh
		. "$LIBDIR/paths.sh"
		uid=$(whs_waydroid_uid 2>/dev/null || true)
		U=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)
	fi
fi
[ -n "$U" ] || { log "skip: cannot determine Waydroid user (set WHS_USER)"; exit 0; }
# fp5 20261120: never start the user manager from here. "systemctl --user -M user@"
# opens a PAM login session; at boot it acquired the homed home half-active and
# started user@UID with HOME=/ (no ~/.config units, keyring lost). Only talk to an
# already running user manager.
_uid=$(id -u "$U" 2>/dev/null || echo x)
if ! systemctl is-active -q "user@$_uid.service" 2>/dev/null || [ ! -S "/run/user/$_uid/bus" ]; then
	log "skip: user manager for $U not running (fp5 home-guard)"; echo "ok:session-not-active(no-user-manager)"; exit 0
fi

mkdir -p "$SDIR" 2>/dev/null || true
prop() { sed -n "s/^$1=//p" | head -n1; }

now=$(date +%s)
sess=$(t systemctl --user -M "$U@" show -p ActiveState -p ActiveEnterTimestamp --timestamp=unix "$SESSION_UNIT" 2>/dev/null)
sess_state=$(printf '%s\n' "$sess" | prop ActiveState)
sess_enter=$(printf '%s\n' "$sess" | prop ActiveEnterTimestamp | tr -d '@')
sess_enter=$(num "$sess_enter" "$now")
age=$((now - sess_enter))

ka="" ever=0 ch=0
if [ -r "$STATUS" ]; then
	ka=$(prop keepalive <"$STATUS")
	ever=$(prop ever <"$STATUS")
	ch=$(prop changed <"$STATUS")
fi
strike=$(cat "$SDIR/strike" 2>/dev/null || echo 0)
last=$(cat "$SDIR/last" 2>/dev/null || echo 0)
cnt=$(cat "$SDIR/count" 2>/dev/null || echo 0)

d=$(whs_attach_decide "${sess_state:-unknown}" "$age" "$ka" "$ever" "$ch" "$strike" "$last" "$cnt" "$now" \
	"$DETACH_MIN" "$RATE" "$MAXB" "$MIN_AGE")
case "$d" in
ok:attached | ok:session-not-active* | ok:no-bridge-status | ok:hal-never-attached*)
	rm -f "$SDIR/strike" 2>/dev/null
	# Quiet when healthy: log only state changes.
	prev=$(cat "$SDIR/state" 2>/dev/null || true)
	[ "$prev" = "$d" ] || log "${d#ok:}"
	echo "$d" >"$SDIR/state" 2>/dev/null
	exit 0
	;;
ok:*)
	log "${d#ok:} -> no action"
	echo "$d" >"$SDIR/state" 2>/dev/null
	exit 0
	;;
strike)
	echo "$now" >"$SDIR/strike" 2>/dev/null
	log "guest HAL detached for $((now - ch))s while the session runs; re-checking before acting"
	echo strike >"$SDIR/state" 2>/dev/null
	exit 0
	;;
esac

log "guest HAL detached for $((now - ch))s (two checks) -> restarting $SESSION_UNIT (user=$U, restart $((cnt + 1))/$MAXB this boot)"
echo "$now" >"$SDIR/last" 2>/dev/null
echo $((cnt + 1)) >"$SDIR/count" 2>/dev/null
rm -f "$SDIR/strike" 2>/dev/null
echo restarted >"$SDIR/state" 2>/dev/null
if t systemctl --user -M "$U@" restart --no-block "$SESSION_UNIT"; then
	log "restart of $SESSION_UNIT queued"
else
	log "warn: restart of $SESSION_UNIT failed (rc=$?)"
fi
exit 0
