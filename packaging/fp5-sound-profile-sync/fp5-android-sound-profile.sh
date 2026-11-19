#!/bin/sh
# Root helper: apply a feedbackd-mirrored Android sound profile.
# Fixed verbs only: silent | quiet | full | restore
# Never writes zen_mode. Never touches volume_music, volume_alarm, volume_voice.
# No notification text, numbers, or other guest payload is printed.
set -eu

VERB=${1:-}
STATE=${STATE_FILE:-/var/lib/waydroid-host-stack/state/android-sound-profile.prev}
STATUS=${STATUS_FILE:-/var/lib/waydroid-host-stack/state/android-sound-profile.status}
LOCK=${LOCK_FILE:-/run/fp5-android-sound-profile.lock}
LXCP=/var/lib/waydroid/lxc
LOGTAG=fp5-android-sound-profile

log() { logger -t "$LOGTAG" -- "$*" 2>/dev/null || echo "$*"; }

case "$VERB" in
  silent|quiet|full|restore) ;;
  *)
    echo "usage: fp5-android-sound-profile.sh silent|quiet|full|restore" >&2
    exit 2
    ;;
esac

is_int() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Fixed commands only; $1 is a literal settings get/put/delete string we build.
lxc_sh() {
  lxc-attach -P "$LXCP" -n waydroid --clear-env -- /system/bin/sh -c "export PATH=/system/bin:/system/xbin; $1"
}

guest_out() {
  lxc_sh "$1" 2>/dev/null | tr -d '\r' | tail -n1
}

guest_ok() {
  v=$(guest_out "settings get system mode_ringer" || true)
  case "$v" in
    null) return 0 ;;
    *) is_int "$v" ;;
  esac
}

get_key() { # ns key
  guest_out "settings get $1 $2" || true
}

put_key() { # ns key value (value already validated)
  lxc_sh "settings put $1 $2 $3" >/dev/null 2>&1
}

del_key() { # ns key
  lxc_sh "settings delete $1 $2" >/dev/null 2>&1 || true
}

restore_key() { # ns key saved
  ns=$1; key=$2; val=${3:-}
  if [ "$val" = "null" ] || [ -z "$val" ]; then
    del_key "$ns" "$key"
    return 0
  fi
  is_int "$val" || { log "refuse restore $key: not an integer"; return 1; }
  put_key "$ns" "$key" "$val"
}

load_state() {
  charging_sounds_enabled=; power_sounds_enabled=
  volume_notification=; volume_system=; volume_ring=; mode_ringer=; zen_mode=
  [ -f "$STATE" ] || { log "missing state file $STATE"; return 1; }
  while IFS='=' read -r k v || [ -n "${k:-}" ]; do
    case "$k" in
      ''|\#*) continue ;;
    esac
    v=$(printf '%s' "$v" | tr -d ' \t\r')
    case "$k" in
      charging_sounds_enabled) charging_sounds_enabled=$v ;;
      power_sounds_enabled) power_sounds_enabled=$v ;;
      volume_notification) volume_notification=$v ;;
      volume_system) volume_system=$v ;;
      volume_ring) volume_ring=$v ;;
      mode_ringer) mode_ringer=$v ;;
      zen_mode) zen_mode=$v ;;
    esac
  done < "$STATE"
}

write_status() { # verb
  mkdir -p "$(dirname "$STATUS")"
  {
    echo "verb=$1"
    echo "applied_at=$(date --iso-8601=seconds 2>/dev/null || date)"
    echo "charging_sounds_enabled=$(get_key global charging_sounds_enabled)"
    echo "power_sounds_enabled=$(get_key global power_sounds_enabled)"
    echo "volume_notification=$(get_key system volume_notification)"
    echo "volume_system=$(get_key system volume_system)"
    echo "volume_ring=$(get_key system volume_ring)"
    echo "mode_ringer=$(get_key system mode_ringer)"
    echo "zen_mode=$(get_key global zen_mode)"
    echo "ok=1"
  } > "$STATUS.tmp"
  chmod 0644 "$STATUS.tmp"
  mv "$STATUS.tmp" "$STATUS"
}

if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  flock 9
fi

if ! lxc-info -P "$LXCP" -n waydroid -s 2>/dev/null | grep -q RUNNING; then
  log "refuse verb=$VERB reason=waydroid-container-not-running"
  exit 4
fi
i=0
while ! guest_ok; do
  i=$((i + 1))
  [ "$i" -le 8 ] || { log "refuse verb=$VERB reason=settings-provider-not-ready"; exit 4; }
  sleep 1
done

rc=0
case "$VERB" in
  silent)
    put_key global charging_sounds_enabled 0 || rc=1
    put_key global power_sounds_enabled 0 || rc=1
    put_key system volume_notification 0 || rc=1
    put_key system volume_system 0 || rc=1
    put_key system volume_ring 0 || rc=1
    put_key system mode_ringer 0 || rc=1
    ;;
  quiet)
    put_key global charging_sounds_enabled 0 || rc=1
    put_key global power_sounds_enabled 0 || rc=1
    put_key system volume_notification 0 || rc=1
    put_key system volume_system 0 || rc=1
    put_key system mode_ringer 1 || rc=1
    ;;
  full|restore)
    load_state || exit 5
    restore_key global charging_sounds_enabled "$charging_sounds_enabled" || rc=1
    restore_key global power_sounds_enabled "$power_sounds_enabled" || rc=1
    restore_key system volume_notification "$volume_notification" || rc=1
    restore_key system volume_system "$volume_system" || rc=1
    restore_key system volume_ring "$volume_ring" || rc=1
    restore_key system mode_ringer "$mode_ringer" || rc=1
    ;;
esac

write_status "$VERB" || true
if [ "$rc" -ne 0 ]; then
  log "applied verb=$VERB result=partial"
  exit 5
fi
log "applied verb=$VERB result=ok"
exit 0
