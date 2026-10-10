#!/bin/sh
# Root loop: inject the host fix (written by waydroid-geoclue-fix) into the
# Waydroid guest's location test providers. Replaces the `sudo -n waydroid shell`
# path of the user-level waydroid-gps-forward loop.
#
# Cheap by design: polls a file's content every $INTERVAL s, only touches the
# container (lxc-attach, no python waydroid CLI) when the fix changed or every
# $KEEPALIVE s, and sets up providers once per container boot.
#
#   waydroid-gps-inject.sh [loop|once|status]
set -eu

FIX="${WAYDROID_GPS_FIX:-/run/waydroid-host-stack/gps-fix}"
STATE="${WAYDROID_GPS_STATE:-/run/waydroid-host-stack/gps-inject}"
LXC_PATH="${WAYDROID_LXC_PATH:-/var/lib/waydroid/lxc}"
INTERVAL="${GPS_INJECT_INTERVAL:-2}"
KEEPALIVE="${GPS_INJECT_KEEPALIVE:-30}"
MAX_AGE="${GPS_INJECT_MAX_AGE:-600}"
mkdir -p "$STATE"

log() { echo "$(date -u +%H:%M:%SZ) $*"; }

container_pid() {
	pid=$(lxc-info -P "$LXC_PATH" -n waydroid -pH 2>/dev/null || true)
	case "$pid" in '' | -1 | *[!0-9]*) return 1 ;; esac
	echo "$pid"
}

# Run a /system/bin/sh snippet in the guest as root.
gsh() {
	lxc-attach -P "$LXC_PATH" -n waydroid --clear-env \
		-v PATH=/product/bin:/apex/com.android.runtime/bin:/system/bin:/system/xbin:/vendor/bin \
		-v ANDROID_ROOT=/system -v ANDROID_DATA=/data -v HOME=/data \
		-- /system/bin/sh -c "$1"
}

guest_booted() {
	[ "$(gsh 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r\n ')" = 1 ]
}

setup_providers() {
	gsh '
settings put global development_settings_enabled 1
settings put secure mock_location 1
appops set com.android.shell android:mock_location allow 2>/dev/null
appops set 2000 android:mock_location allow 2>/dev/null
appops set 0 android:mock_location allow 2>/dev/null
cmd location set-location-enabled true 2>/dev/null
for p in gps network; do
  cmd location providers add-test-provider $p --supportsAltitude --supportsSpeed --supportsBearing --powerRequirement 1 2>/dev/null
  cmd location providers set-test-provider-enabled $p true 2>/dev/null
done
echo GPS_SETUP_OK' 2>&1 | grep -q GPS_SETUP_OK
}

# inject LAT LON ACC
inject() {
	nacc=$(awk -v a="$3" 'BEGIN{a=a+0; if (a<30) a=30; printf "%.1f", a}')
	out=$(gsh "cmd location providers set-test-provider-location gps --location $1,$2 --accuracy $3; g=\$?; cmd location providers set-test-provider-location network --location $1,$2 --accuracy $nacc; echo GPS_INJECT_RC=\$g" 2>&1 || true)
	case "$out" in *GPS_INJECT_RC=0*) return 0 ;; esac
	log "inject failed: $(echo "$out" | tr '\n' ' ' | cut -c1-200)"
	return 1
}

# Validate numbers so nothing odd reaches the guest shell.
valid_num() { case "$1" in '' | *[!0-9.+-]*) return 1 ;; esac; }

once() {
	[ -s "$FIX" ] || { log "no host fix yet ($FIX)"; return 1; }
	IFS='|' read -r lat lon acc _alt _spd _hdg ts _desc <"$FIX" || return 1
	valid_num "$lat" && valid_num "$lon" || { log "bad fix line"; return 1; }
	valid_num "$acc" || acc=50
	now=$(date +%s)
	if [ -n "${ts:-}" ] && [ $((now - ts)) -gt "$MAX_AGE" ]; then
		log "host fix stale ($((now - ts))s) — injecting last known anyway"
	fi
	pid=$(container_pid) || { rm -f "$STATE/setup-pid"; return 1; }
	if [ "$(cat "$STATE/setup-pid" 2>/dev/null)" != "$pid" ]; then
		guest_booted || return 1
		setup_providers || { log "provider setup failed"; return 1; }
		echo "$pid" >"$STATE/setup-pid"
		log "providers ready (container pid=$pid)"
	fi
	if inject "$lat" "$lon" "$acc"; then
		echo "$lat|$lon|$acc" >"$STATE/last"
		date +%s >"$STATE/last-ts"
		return 0
	fi
	rm -f "$STATE/setup-pid"
	return 1
}

loop() {
	log "waydroid-gps-inject loop fix=$FIX interval=${INTERVAL}s keepalive=${KEEPALIVE}s"
	last=""
	last_t=0
	ok_logged=""
	while :; do
		cur=$(cut -d'|' -f1-3 "$FIX" 2>/dev/null || true)
		now=$(date +%s)
		if [ -n "$cur" ] && { [ "$cur" != "$last" ] || [ $((now - last_t)) -ge "$KEEPALIVE" ]; }; then
			if once; then
				[ "$cur" = "$ok_logged" ] || log "INJECT_OK $cur"
				ok_logged=$cur
				last=$cur
			fi
			last_t=$now
		fi
		sleep "$INTERVAL"
	done
}

case "${1:-loop}" in
loop) loop ;;
once) once && echo "GPS_INJECT_OK $(cat "$STATE/last")" ;;
status)
	echo "fix: $(cat "$FIX" 2>/dev/null || echo none)"
	echo "last_inject: $(cat "$STATE/last" 2>/dev/null || echo none) at $(cat "$STATE/last-ts" 2>/dev/null || echo -)"
	;;
*) echo "usage: $0 [loop|once|status]" >&2; exit 2 ;;
esac
