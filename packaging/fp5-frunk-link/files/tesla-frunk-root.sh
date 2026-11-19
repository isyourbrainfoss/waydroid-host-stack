#!/bin/sh
# /var/lib/fp5-tesla/bin/tesla-frunk-root.sh (root:root 0755), run by tesla-frunk.service.
# Fires the same intent as the Tesla phone-key notification's "Front Trunk" button
# (PendingIntent requestCode=14: com.teslamotors.ble.action.COMMAND -> PhoneKeyCommandReceiver),
# but ONLY if BlueZ has a live LE link to the car's phone-key (VCSEC) device AND that
# notification says "Connected" and offers "Front Trunk". The notification alone can be
# stale (17 Nov 2026: link lost while the app kept showing "Connected").
#
# 2026-11-19 (FP5, Kristian's yes): if the link is not up when the tile is pressed, ask
# waydroid-bt-host for one active connect (SIGUSR1 "kick", only if the running bridge
# advertises it in /run/waydroid-bt/features) and wait up to FRUNK_WAIT_S (10 s) for
# link + "Connected"; the safety checks above are unchanged. One journal line per press
# (tag tesla-frunk): result, reason, timings. No addresses, VIN or names are printed.
# Exit 0 = sent, 3 = car not connected, 4 = Waydroid not running, 5 = send failed, 6 = busy.
# Test mode (never sends anything):  tesla-frunk-root.sh --check-only [dumpsys-file]
set -u
LXCP=/var/lib/waydroid/lxc
WAIT_S=${FRUNK_WAIT_S:-10}
FEATURES=${FRUNK_FEATURES_FILE:-/run/waydroid-bt/features}
LOCK=${FRUNK_LOCK:-/run/tesla-frunk.lock}
lxc_sh() { lxc-attach -P "$LXCP" -n waydroid --clear-env -- /system/bin/sh -c "export PATH=/system/bin; $1"; }
now_ms() { awk '{ printf "%d\n", $1 * 1000 }' /proc/uptime; }

VCSEC=00000211-b2d1-43f0-9b88-960cebf8b91e   # Tesla vehicle-security GATT service
ble_link() {    # stdout: up | down. No addresses printed.
  for d in $(busctl tree org.bluez 2>/dev/null | grep -oE '/org/bluez/hci[0-9]+/dev_[0-9A-F_]+$' | sort -u); do
    busctl get-property org.bluez "$d" org.bluez.Device1 UUIDs 2>/dev/null | grep -qi "$VCSEC" || continue
    [ "$(busctl get-property org.bluez "$d" org.bluez.Device1 Connected 2>/dev/null)" = "b true" ] && { echo up; return; }
  done
  echo down
}

key_state() {   # stdin: `dumpsys notification --noredact`; stdout: ok | nobutton | notconnected
  awk '
    /^  Snoozed notifications:/ { exit }   # only the live "Notification List"
    /NotificationRecord\(/ { inrec = ($0 ~ /pkg=com\.teslamotors\.tesla / && $0 ~ /phone_key_service_channel/) }
    inrec && /"Front Trunk"/ { ft = 1 }
    inrec && /android\.text=String \(Connected\)/ { c = 1 }
    END { if (c && ft) print "ok"; else if (c) print "nobutton"; else print "notconnected" }'
}

# kick the bridge: SIGUSR1 only if the RUNNING bridge says it handles it (an old one would exit)
kick_bridge() { # stdout: sent | unsupported | no-bridge
  pid=$(systemctl show -p MainPID --value waydroid-bt-host.service 2>/dev/null)
  [ -n "$pid" ] && [ "$pid" != 0 ] || { echo no-bridge; return; }
  grep -q "^kick-usr1 .*pid=$pid\$" "$FEATURES" 2>/dev/null || { echo unsupported; return; }
  kill -USR1 "$pid" 2>/dev/null && echo sent || echo no-bridge
}

log() { logger -t tesla-frunk -- "$*" 2>/dev/null || echo "$*"; }

if [ "${1:-}" = "--check-only" ]; then
  if [ -n "${2:-}" ]; then key_state < "$2"; exit 0; fi
  echo "notification=$(lxc_sh 'dumpsys notification --noredact' 2>/dev/null | key_state) ble_link=$(ble_link)"
  exit 0
fi

# no double sends: one press at a time (systemd oneshot already joins concurrent starts)
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  flock -n 9 || { log "press result=busy reason=another-press-running"; exit 6; }
fi

t0=$(now_ms)
lxc-info -P "$LXCP" -n waydroid -s 2>/dev/null | grep -q RUNNING || {
  log "press result=refused reason=waydroid-not-running"; exit 4; }

link0=$(ble_link); kick=none; link=$link0; state=unchecked
[ "$link0" = up ] || kick=$(kick_bridge)
deadline=$((t0 + WAIT_S * 1000))
while :; do
  [ "$link" = up ] || link=$(ble_link)
  if [ "$link" = up ]; then
    state=$(lxc_sh 'dumpsys notification --noredact' 2>/dev/null | key_state)
    [ "$state" = ok ] && break
    [ "$(ble_link)" = up ] || link=down
  fi
  [ "$(now_ms)" -ge "$deadline" ] && break
  sleep 0.5
done
waited=$(( $(now_ms) - t0 ))
info="link_at_press=$link0 kick=$kick link=$link key=$state waited_ms=$waited"

if [ "$link" != up ]; then log "press result=refused reason=no-car-link $info"; exit 3; fi
case "$state" in
  ok) ;;
  nobutton) log "press result=refused reason=no-front-trunk-action $info"; exit 3 ;;
  *) log "press result=refused reason=phone-key-not-connected $info"; exit 3 ;;
esac
if lxc_sh 'am broadcast -a com.teslamotors.ble.action.COMMAND -n com.teslamotors.tesla/com.teslamotors.plugins.ble.PhoneKeyCommandReceiver --ei command_id 14' 2>/dev/null | grep -q 'result=0'; then
  log "press result=sent $info"; exit 0
fi
log "press result=send-failed $info"; exit 5
