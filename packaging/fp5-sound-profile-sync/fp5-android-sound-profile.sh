#!/bin/sh
# Root helper: apply a feedbackd-mirrored Android sound profile.
# Fixed verbs only: silent | quiet | full | restore
# Never writes zen_mode. Never touches volume_music, volume_alarm, volume_voice.
# No notification text or other guest payload is printed.
#
# Android 13 (API 33) on this Waydroid image has no `cmd audio set-ringer-mode`
# (AudioManagerShellCommand only exposes surround-format commands). Live state
# is changed with IAudioService service calls, transaction codes taken from
# this image's IAudioService$Stub (framework.jar):
#   setRingerModeExternal=40  getRingerModeExternal=42
#   setRingerModeInternal=74  getRingerModeInternal=75
#   setStreamVolume=135       getStreamVolume=177
#   getStreamMaxVolume=21     getUiSoundsStreamType=45
# `cmd media_session volume --stream N --get/--set` is tried first for volumes;
# service call is the fallback and the verification path.
# Settings.Global charging_sounds_enabled / power_sounds_enabled are still
# written: the system server reads charging_sounds_enabled live (next to
# charging_started_sound). volume_*/mode_ringer Settings are also persisted
# for the next guest boot, but they are not what AudioService uses live.
set -eu

VERB=${1:-}
STATE=${STATE_FILE:-/var/lib/waydroid-host-stack/state/android-sound-profile.prev}
STATUS=${STATUS_FILE:-/var/lib/waydroid-host-stack/state/android-sound-profile.status}
LOCK=${LOCK_FILE:-/run/fp5-android-sound-profile.lock}
LXCP=/var/lib/waydroid/lxc
LOGTAG=fp5-android-sound-profile
CALLER=com.android.shell

# IAudioService transaction codes (this Android 13 image only)
TX_SET_RINGER_EXT=40
TX_GET_RINGER_EXT=42
TX_SET_RINGER_INT=74
TX_GET_RINGER_INT=75
TX_SET_STREAM_VOLUME=135
TX_GET_STREAM_VOLUME=177
TX_GET_UI_SOUNDS_STREAM=45

STREAM_VOICE=0
STREAM_SYSTEM=1
STREAM_RING=2
STREAM_NOTIFICATION=5

RINGER_SILENT=0
RINGER_VIBRATE=1
RINGER_NORMAL=2

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
    *) is_int "$v" && return 0 ;;
  esac
  # live get is a better readiness check
  v=$(live_get_ringer || true)
  is_int "$v"
}

get_key() { # ns key
  guest_out "settings get $1 $2" || true
}

put_key() { # ns key value
  lxc_sh "settings put $1 $2 $3" >/dev/null 2>&1
}

del_key() { # ns key
  lxc_sh "settings delete $1 $2" >/dev/null 2>&1 || true
}

restore_settings_key() { # ns key saved
  ns=$1; key=$2; val=${3:-}
  if [ "$val" = "null" ] || [ -z "$val" ]; then
    del_key "$ns" "$key"
    return 0
  fi
  is_int "$val" || { log "refuse restore $key: not an integer"; return 1; }
  put_key "$ns" "$key" "$val"
}

# Parse `service call` reply. AIDL writeNoException() then writeInt(value):
#   Result: Parcel(00000000 00000005  '........')  -> 5
# void methods only have the exception word.
parcel_int() {
  hexes=$(printf '%s' "$1" | sed -n 's/.*Parcel(\([^)]*\)).*/\1/p' | grep -oE '[0-9A-Fa-f]{8}' || true)
  set -- $hexes
  if [ $# -ge 2 ] && [ "$1" = "00000000" ]; then
    printf '%d\n' "0x$2"
    return 0
  fi
  if [ $# -ge 1 ]; then
    printf '%d\n' "0x$1"
    return 0
  fi
  return 1
}

svc() { # args after `service call audio`
  lxc_sh "service call audio $*" 2>/dev/null
}

live_get_ringer() {
  out=$(svc "$TX_GET_RINGER_EXT" || true)
  parcel_int "$out" 2>/dev/null || true
}

live_set_ringer() { # 0/1/2
  mode=$1
  is_int "$mode" || return 1
  svc "$TX_SET_RINGER_EXT" i32 "$mode" s16 "$CALLER" >/dev/null 2>&1 || true
  got=$(live_get_ringer || true)
  if [ "$got" = "$mode" ]; then
    return 0
  fi
  # If External did not stick, try Internal (still no zen_mode).
  svc "$TX_SET_RINGER_INT" i32 "$mode" s16 "$CALLER" >/dev/null 2>&1 || true
  got=$(live_get_ringer || true)
  [ "$got" = "$mode" ]
}

# volume get: media_session first, then service call
live_get_stream() { # N
  n=$1
  out=$(lxc_sh "cmd media_session volume --stream $n --get" 2>/dev/null || true)
  # typical: "volume is 5 in range [0..7]" or a bare integer
  v=$(printf '%s' "$out" | tr -d '\r' | grep -oE 'volume is [0-9]+' | grep -oE '[0-9]+' | tail -n1 || true)
  if [ -z "$v" ]; then
    v=$(printf '%s' "$out" | tr -d '\r' | grep -oE '^[0-9]+$' | tail -n1 || true)
  fi
  if is_int "$v"; then
    printf '%s\n' "$v"
    return 0
  fi
  out=$(svc "$TX_GET_STREAM_VOLUME" i32 "$n" || true)
  parcel_int "$out" 2>/dev/null || true
}

live_set_stream() { # N VAL
  n=$1; val=$2
  is_int "$n" && is_int "$val" || return 1
  # flags=0: no UI, no feedback sound
  lxc_sh "cmd media_session volume --stream $n --set $val" >/dev/null 2>&1 || true
  got=$(live_get_stream "$n" || true)
  if [ "$got" = "$val" ]; then
    return 0
  fi
  svc "$TX_SET_STREAM_VOLUME" i32 "$n" i32 "$val" i32 0 s16 "$CALLER" >/dev/null 2>&1 || true
  got=$(live_get_stream "$n" || true)
  [ "$got" = "$val" ]
}

load_state() {
  charging_sounds_enabled=; power_sounds_enabled=
  volume_notification=; volume_system=; volume_ring=; mode_ringer=; zen_mode=
  live_ringer_mode=; live_volume_notification=; live_volume_system=; live_volume_ring=
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
      live_ringer_mode) live_ringer_mode=$v ;;
      live_volume_notification) live_volume_notification=$v ;;
      live_volume_system) live_volume_system=$v ;;
      live_volume_ring) live_volume_ring=$v ;;
    esac
  done < "$STATE"
}

# Prefer live_* snapshots; fall back to Settings values (or NORMAL/0).
restore_target() { # live_val settings_val default
  if is_int "${1:-}"; then printf '%s\n' "$1"
  elif is_int "${2:-}"; then printf '%s\n' "$2"
  else printf '%s\n' "$3"
  fi
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
    echo "live_ringer_mode=$(live_get_ringer)"
    echo "live_volume_notification=$(live_get_stream $STREAM_NOTIFICATION)"
    echo "live_volume_system=$(live_get_stream $STREAM_SYSTEM)"
    echo "live_volume_ring=$(live_get_stream $STREAM_RING)"
    echo "ui_sounds_stream=$(parcel_int "$(svc $TX_GET_UI_SOUNDS_STREAM || true)" 2>/dev/null || true)"
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
    put_key system volume_notification 0 || true
    put_key system volume_system 0 || true
    put_key system volume_ring 0 || true
    put_key system mode_ringer 0 || true
    put_key global mode_ringer 0 || true
    live_set_stream "$STREAM_NOTIFICATION" 0 || rc=1
    live_set_stream "$STREAM_SYSTEM" 0 || rc=1
    live_set_stream "$STREAM_RING" 0 || rc=1
    live_set_ringer "$RINGER_SILENT" || rc=1
    ;;
  quiet)
    put_key global charging_sounds_enabled 0 || rc=1
    put_key global power_sounds_enabled 0 || rc=1
    put_key system volume_notification 0 || true
    put_key system volume_system 0 || true
    put_key system mode_ringer 1 || true
    put_key global mode_ringer 1 || true
    live_set_stream "$STREAM_NOTIFICATION" 0 || rc=1
    live_set_stream "$STREAM_SYSTEM" 0 || rc=1
    live_set_stream "$STREAM_RING" 0 || rc=1
    live_set_ringer "$RINGER_VIBRATE" || rc=1
    ;;
  full|restore)
    load_state || exit 5
    restore_settings_key global charging_sounds_enabled "$charging_sounds_enabled" || rc=1
    restore_settings_key global power_sounds_enabled "$power_sounds_enabled" || rc=1
    restore_settings_key system volume_notification "$volume_notification" || true
    restore_settings_key system volume_system "$volume_system" || true
    restore_settings_key system volume_ring "$volume_ring" || true
    # mode_ringer in Settings was null at install; only put if we have a number
    if is_int "${mode_ringer:-}"; then
      put_key system mode_ringer "$mode_ringer" || true
      put_key global mode_ringer "$mode_ringer" || true
    fi
    tn=$(restore_target "${live_volume_notification:-}" "${volume_notification:-}" 5)
    ts=$(restore_target "${live_volume_system:-}" "${volume_system:-}" 7)
    tr=$(restore_target "${live_volume_ring:-}" "${volume_ring:-}" 5)
    tm=$(restore_target "${live_ringer_mode:-}" "${mode_ringer:-}" 2)
    live_set_stream "$STREAM_NOTIFICATION" "$tn" || rc=1
    live_set_stream "$STREAM_SYSTEM" "$ts" || rc=1
    live_set_stream "$STREAM_RING" "$tr" || rc=1
    live_set_ringer "$tm" || rc=1
    ;;
esac

write_status "$VERB" || true
if [ "$rc" -ne 0 ]; then
  log "applied verb=$VERB result=partial"
  exit 5
fi
log "applied verb=$VERB result=ok"
exit 0
