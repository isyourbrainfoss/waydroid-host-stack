#!/bin/sh
# One-shot root update: probe live audio, save live restore values, back up
# the v1 settings-put helper, install the live helper, apply silent, print.
# No zen_mode. No restarts of waydroid-session, PipeWire, or feedbackd.
set -eu
cd "$(dirname "$0")"
B=/var/lib/fp5-backup/20261119-sound-sync
STATE=/var/lib/waydroid-host-stack/state/android-sound-profile.prev
HELPER=/var/lib/waydroid-host-stack/sbin/fp5-android-sound-profile.sh
LXCP=/var/lib/waydroid/lxc
TX_GET_RINGER_EXT=40
# typo guard — get is 42
TX_GET_RINGER_EXT=42
TX_GET_RINGER_INT=75
TX_GET_STREAM_VOLUME=177
TX_GET_UI_SOUNDS_STREAM=45

redact() {
  sed -E 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/[IP]/g; s/([0-9A-Fa-f]{2}[:_]){5}[0-9A-Fa-f]{2}/[MAC]/g'
}

lxc_sh() {
  lxc-attach -P "$LXCP" -n waydroid --clear-env -- /system/bin/sh -c "export PATH=/system/bin:/system/xbin; $1"
}

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

svc() { lxc_sh "service call audio $*" 2>/dev/null; }

live_get_ringer() { parcel_int "$(svc $TX_GET_RINGER_EXT || true)" 2>/dev/null || true; }
live_get_stream() {
  n=$1
  out=$(lxc_sh "cmd media_session volume --stream $n --get" 2>/dev/null || true)
  v=$(printf '%s' "$out" | tr -d '\r' | grep -oE 'volume is [0-9]+' | grep -oE '[0-9]+' | tail -n1 || true)
  if [ -z "$v" ]; then
    v=$(printf '%s' "$out" | tr -d '\r' | grep -oE '^[0-9]+$' | tail -n1 || true)
  fi
  case "$v" in
    ''|*[!0-9]*) parcel_int "$(svc $TX_GET_STREAM_VOLUME i32 $n || true)" 2>/dev/null || true ;;
    *) printf '%s\n' "$v" ;;
  esac
}

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root" >&2
  exit 1
fi
if ! lxc-info -P "$LXCP" -n waydroid -s 2>/dev/null | grep -q RUNNING; then
  echo "ERROR: Waydroid container is not running" >&2
  exit 4
fi

mkdir -p "$B"

# 1. Probe (redacted, no notification bodies)
PROBE=$B/probe-live-audio.txt
{
  echo "===== captured_at=$(date --iso-8601=seconds) ====="
  echo "===== cmd audio (help) ====="
  lxc_sh "cmd audio help" 2>&1 | redact | head -80 || true
  echo "===== cmd audio (no args) ====="
  lxc_sh "cmd audio" 2>&1 | redact | head -80 || true
  echo "===== cmd media_session volume (no args / help) ====="
  lxc_sh "cmd media_session volume" 2>&1 | redact | head -40 || true
  lxc_sh "cmd media_session help" 2>&1 | redact | head -60 || true
  echo "===== media_session volume --get streams 0-5 ====="
  for n in 0 1 2 3 4 5; do
    echo -n "stream $n: "
    lxc_sh "cmd media_session volume --stream $n --get" 2>&1 | tr -d '\r' | redact | tr '\n' ' '
    echo
  done
  echo "===== service call get ringer/volumes ====="
  echo -n "getRingerModeExternal: "; svc $TX_GET_RINGER_EXT | redact; echo
  echo -n "getRingerModeInternal: "; svc $TX_GET_RINGER_INT | redact; echo
  for n in 0 1 2 3 4 5; do
    echo -n "getStreamVolume $n: "; svc $TX_GET_STREAM_VOLUME i32 $n | redact; echo
  done
  echo -n "getUiSoundsStreamType: "; svc $TX_GET_UI_SOUNDS_STREAM | redact; echo
  echo "===== dumpsys audio (ringer, volumes, alias only) ====="
  lxc_sh "dumpsys audio" 2>/dev/null | redact | grep -Ei \
    'ringer mode|STREAM_VOLUME|STREAM_VOICE|STREAM_SYSTEM|STREAM_RING|STREAM_MUSIC|STREAM_ALARM|STREAM_NOTIFICATION|streamVolumeAlias|volume alias|UiSounds|ui sounds|muted' \
    | grep -viE 'waydroid-gps-inject|geoclue|gnome-calls|wpa_supplicant' \
    | head -80 || true
} > "$PROBE"
chmod 0644 "$PROBE"
echo "probe written to $PROBE"

# 2. Save LIVE restore values BEFORE changing anything live
# Keep android-restore.conf.orig (Settings snapshot from first install).
LIVE_RING=$(live_get_ringer || true)
LIVE_NOTIF=$(live_get_stream 5 || true)
LIVE_SYS=$(live_get_stream 1 || true)
LIVE_RINGVOL=$(live_get_stream 2 || true)
LIVE_MUSIC=$(live_get_stream 3 || true)
LIVE_ALARM=$(live_get_stream 4 || true)
LIVE_VOICE=$(live_get_stream 0 || true)
UI_STREAM=$(parcel_int "$(svc $TX_GET_UI_SOUNDS_STREAM || true)" 2>/dev/null || true)

echo "LIVE before apply: ringer=$LIVE_RING notif=$LIVE_NOTIF system=$LIVE_SYS ring=$LIVE_RINGVOL music=$LIVE_MUSIC alarm=$LIVE_ALARM voice=$LIVE_VOICE ui_sounds_stream=$UI_STREAM"

# Merge live_* into the restore file; do not drop existing Settings keys.
TMP=$B/android-restore.conf.new
if [ -f "$B/android-restore.conf" ]; then
  grep -vE '^live_|^ui_sounds_stream=|^captured_live_at=' "$B/android-restore.conf" > "$TMP" || true
else
  : > "$TMP"
fi
{
  echo "captured_live_at=$(date --iso-8601=seconds 2>/dev/null || date)"
  echo "live_ringer_mode=${LIVE_RING}"
  echo "live_volume_notification=${LIVE_NOTIF}"
  echo "live_volume_system=${LIVE_SYS}"
  echo "live_volume_ring=${LIVE_RINGVOL}"
  echo "live_volume_music=${LIVE_MUSIC}"
  echo "live_volume_alarm=${LIVE_ALARM}"
  echo "live_volume_voice=${LIVE_VOICE}"
  echo "ui_sounds_stream=${UI_STREAM}"
} >> "$TMP"
mv "$TMP" "$B/android-restore.conf"
chmod 0644 "$B/android-restore.conf"
cp -a "$B/android-restore.conf" "$STATE"
echo "saved live restore values to $B/android-restore.conf and $STATE"

# 3. Back up the v1 settings-put helper, then install the new one
if [ -f "$HELPER" ]; then
  cp -a "$HELPER" "$B/fp5-android-sound-profile.sh.v1-settings-put"
  echo "backed up v1 helper"
fi
install -o root -g root -m 0755 fp5-android-sound-profile.sh "$HELPER"
echo "installed new helper"

# 4. Apply silent (current feedbackd profile). Do not restart the user service.
"$HELPER" silent
echo "helper silent exit=$?"

# 5. Print live values after silent
echo "===== LIVE after silent ====="
echo "ringer=$(live_get_ringer)"
echo "volume_notification=$(live_get_stream 5)"
echo "volume_system=$(live_get_stream 1)"
echo "volume_ring=$(live_get_stream 2)"
echo "volume_music=$(live_get_stream 3) (must be unchanged, not muted)"
echo "volume_alarm=$(live_get_stream 4) (must be unchanged, not muted)"
echo "volume_voice=$(live_get_stream 0) (must be unchanged, not muted)"
echo "ui_sounds_stream=$(parcel_int "$(svc $TX_GET_UI_SOUNDS_STREAM || true)" 2>/dev/null || true)"
echo "===== status file ====="
cat /var/lib/waydroid-host-stack/state/android-sound-profile.status
echo "===== restore file ====="
cat "$B/android-restore.conf"
echo "update done"
