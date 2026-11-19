#!/bin/sh
# Roll back the feedbackd-Android sound profile sync. Dry-run unless --apply.
# Restores saved Android values, sets event-sounds true (or the saved host value),
# disables the user unit, and removes files installed as "new".
set -eu
B=/var/lib/fp5-backup/20261119-sound-sync
A=${1:-}
FP5=fp5
FP5_UID=60434
FP5_HOME=/home/fp5

run() { if [ "$A" = --apply ]; then "$@"; else echo "would: $*"; fi; }

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root: run0 sh $B/rollback.sh --apply" >&2
  exit 1
fi

as_fp5() {
  # Become fp5 with the existing session bus. Use setpriv (not run0) so this
  # already-root script does not pop a second password prompt.
  env HOME="$FP5_HOME" XDG_RUNTIME_DIR=/run/user/$FP5_UID     DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$FP5_UID/bus     setpriv --reuid="$FP5_UID" --regid="$FP5_UID" --init-groups -- "$@"
}

# Stop and disable the user watcher first (no other services).
run systemctl --user -M ${FP5}@ disable --now fp5-feedbackd-profile-sync.service || true

# Restore host event-sounds (saved, default true)
ev=true
if [ -f "$B/host-restore.conf" ]; then
  ev=$(sed -n 's/^event_sounds=//p' "$B/host-restore.conf" | tail -n1)
  [ -n "$ev" ] || ev=true
fi
run as_fp5 gsettings set org.gnome.desktop.sound event-sounds "$ev"

# Restore Android values while the helper is still installed
if [ "$A" = --apply ]; then
  if [ -x /var/lib/waydroid-host-stack/sbin/fp5-android-sound-profile.sh ]; then
    # Prefer the orig capture if present
    if [ -f "$B/android-restore.conf.orig" ]; then
      cp -a "$B/android-restore.conf.orig" /var/lib/waydroid-host-stack/state/android-sound-profile.prev
    fi
    /var/lib/waydroid-host-stack/sbin/fp5-android-sound-profile.sh restore
  else
    echo "helper already missing; cannot restore Android values" >&2
  fi
else
  echo "would: helper restore from $B/android-restore.conf"
fi

# Remove or restore files from the manifest
if [ -f "$B/manifest" ]; then
  while read -r kind f; do
    case "$kind" in
      existed) run cp -a "$B/orig$f" "$f" ;;
      new) run rm -f "$f" ;;
    esac
  done < "$B/manifest"
fi

run systemctl daemon-reload
run systemctl --user -M ${FP5}@ daemon-reload || true
echo "rollback ${A:-dry-run} done"
