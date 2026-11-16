#!/bin/sh
# ExecStartPost helper for waydroid-bt-host.service (runs as root, "-+" prefix).
#
# After the bridge is (re)started while a Waydroid session is already up, the
# guest HAL stays attached to the old bridge and never reconnects. Restart the
# session user unit so Android always reconnects to the new bridge.
#
# Restart only if ALL hold:
#   * WHS_SESSION_RESTART is not 0
#   * the session user unit is active
#   * it entered "active" BEFORE this bridge instance started (so never at
#     boot / first start, and never for a session that started after us)
#   * no restart was done by this helper in the last WHS_SESSION_RESTART_DEBOUNCE
#     seconds (default 60; state in /run/waydroid-bt, survives bridge restarts)
# Fail-soft: always exits 0; every systemctl call is time-limited.
#
# Config (environment): WHS_USER, WAYDROID_UID (see lib/paths.sh),
#   WHS_SESSION_UNIT (default waydroid-session.service),
#   WHS_BRIDGE_UNIT (default waydroid-bt-host.service),
#   WHS_SESSION_RESTART_STATE (default /run/waydroid-bt/session-restart.last).
set -u

log() { echo "session-restart: $*"; }

SESSION_UNIT="${WHS_SESSION_UNIT:-waydroid-session.service}"
BRIDGE_UNIT="${WHS_BRIDGE_UNIT:-waydroid-bt-host.service}"
STATE="${WHS_SESSION_RESTART_STATE:-/run/waydroid-bt/session-restart.last}"
DEBOUNCE="${WHS_SESSION_RESTART_DEBOUNCE:-60}"
TMO="${WHS_SESSION_RESTART_TIMEOUT:-10}"

case "${WHS_SESSION_RESTART:-1}" in
0 | no | false | off) log "disabled (WHS_SESSION_RESTART=0)"; exit 0 ;;
esac
case "$DEBOUNCE" in '' | *[!0-9]*) DEBOUNCE=60 ;; esac
case "$TMO" in '' | *[!0-9]*) TMO=10 ;; esac

t() {
	if command -v timeout >/dev/null 2>&1; then timeout "$TMO" "$@"; else "$@"; fi
}

# whs_decide BRIDGE_START_US SESSION_STATE SESSION_ENTER_US LAST_EPOCH NOW_EPOCH DEBOUNCE
# -> prints "restart" or "skip:<reason>". Pure; used by the selftest.
whs_decide() {
	b="$1" st="$2" se="$3" last="$4" now="$5" db="$6"
	[ "$st" = active ] || { echo "skip:session-not-active($st)"; return 0; }
	case "$se" in '' | 0 | *[!0-9]*) echo "skip:session-start-unknown"; return 0 ;; esac
	case "$b" in '' | 0 | *[!0-9]*) echo "skip:bridge-start-unknown"; return 0 ;; esac
	[ "$se" -lt "$b" ] || { echo "skip:session-started-after-bridge"; return 0; }
	case "$last" in '' | *[!0-9]*) last=0 ;; esac
	if [ "$last" -gt 0 ] && [ $((now - last)) -lt "$db" ]; then
		echo "skip:debounce($((now - last))s<${db}s)"
		return 0
	fi
	echo restart
}

[ "${1:-}" = --decide ] && { shift; whs_decide "$@"; exit 0; }

# Resolve the Waydroid user: WHS_USER wins, else lib/paths.sh whs_waydroid_uid
# (waydroid.prop host.uid, WAYDROID_UID, ...).
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

prop() { sed -n "s/^$1=//p" | head -n1; }

bridge_us=$(t systemctl show -p ExecMainStartTimestampMonotonic "$BRIDGE_UNIT" 2>/dev/null | prop ExecMainStartTimestampMonotonic)
sess=$(t systemctl --user -M "$U@" show -p ActiveState -p ActiveEnterTimestampMonotonic "$SESSION_UNIT" 2>/dev/null)
sess_state=$(printf '%s\n' "$sess" | prop ActiveState)
sess_us=$(printf '%s\n' "$sess" | prop ActiveEnterTimestampMonotonic)
last=$(cat "$STATE" 2>/dev/null || echo 0)
now=$(date +%s)

d=$(whs_decide "${bridge_us:-}" "${sess_state:-unknown}" "${sess_us:-}" "$last" "$now" "$DEBOUNCE")
if [ "$d" != restart ]; then
	log "${d#skip:} -> not restarting $SESSION_UNIT (user=$U)"
	exit 0
fi

log "session was running before this bridge start -> restarting $SESSION_UNIT (user=$U)"
echo "$now" >"$STATE" 2>/dev/null || log "warn: cannot write $STATE (debounce off)"
if t systemctl --user -M "$U@" restart --no-block "$SESSION_UNIT"; then
	log "restart of $SESSION_UNIT queued"
else
	log "warn: restart of $SESSION_UNIT failed (rc=$?), bridge keeps running"
fi
exit 0
