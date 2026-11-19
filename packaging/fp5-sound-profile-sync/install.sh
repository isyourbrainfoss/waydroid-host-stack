#!/bin/sh
# Install the feedbackd <-> Android sound profile sync. Run as root from this directory.
# Backs up first, saves current Android values, then installs. Does not restart
# PipeWire, feedbackd, waydroid-session, phoc, greetd; no reboot; no sysext refresh.
set -eu
cd "$(dirname "$0")"
B=/var/lib/fp5-backup/20261119-sound-sync
STATE=/var/lib/waydroid-host-stack/state/android-sound-profile.prev
FP5=fp5
FP5_HOME=/home/fp5
FP5_UID=60434

guest_get() {
  lxc-attach -P /var/lib/waydroid/lxc -n waydroid --clear-env -- /system/bin/sh -c     "export PATH=/system/bin:/system/xbin; settings get $1 $2" 2>/dev/null | tr -d '\r' | tail -n1
}

as_fp5() {
  # Become fp5 with the existing session bus. Use setpriv (not run0) so this
  # already-root script does not pop a second password prompt.
  env HOME="$FP5_HOME" XDG_RUNTIME_DIR=/run/user/$FP5_UID     DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$FP5_UID/bus     setpriv --reuid="$FP5_UID" --regid="$FP5_UID" --init-groups -- "$@"
}

mkdir -p "$B/orig"
: > "$B/manifest"

record() {
  f=$1
  if [ -e "$f" ]; then
    mkdir -p "$B/orig$(dirname "$f")"
    cp -a "$f" "$B/orig$f"
    echo "existed $f" >> "$B/manifest"
  else
    echo "new $f" >> "$B/manifest"
  fi
}

for f in \
  /var/lib/waydroid-host-stack/sbin/fp5-android-sound-profile.sh \
  /etc/systemd/system/fp5-android-sound-profile@.service \
  /etc/polkit-1/rules.d/60-fp5-android-sound-profile.rules \
  $FP5_HOME/.local/bin/fp5-feedbackd-profile-sync \
  $FP5_HOME/.local/bin/fp5-event-role-restore \
  $FP5_HOME/.local/bin/fp5-clocks-alarm-sound \
  $FP5_HOME/.config/systemd/user/fp5-feedbackd-profile-sync.service \
  $FP5_HOME/.config/systemd/user/fp5-clocks-alarm-sound.service \
  $STATE
 do
  record "$f"
done

# Host settings (for rollback / restore documentation)
{
  echo "captured_at=$(date --iso-8601=seconds 2>/dev/null || date)"
  echo "event_sounds=$(as_fp5 gsettings get org.gnome.desktop.sound event-sounds 2>/dev/null | tr -d "' " || true)"
  echo "feedbackd_profile=$(as_fp5 gsettings get org.sigxcpu.feedbackd profile 2>/dev/null | tr -d "' " || true)"
} > "$B/host-restore.conf"

# Android values BEFORE any change
if ! lxc-info -P /var/lib/waydroid/lxc -n waydroid -s 2>/dev/null | grep -q RUNNING; then
  echo "ERROR: Waydroid container is not running; cannot save Android restore state" >&2
  exit 4
fi
{
  echo "captured_at=$(date --iso-8601=seconds 2>/dev/null || date)"
  echo "charging_sounds_enabled=$(guest_get global charging_sounds_enabled)"
  echo "power_sounds_enabled=$(guest_get global power_sounds_enabled)"
  echo "volume_notification=$(guest_get system volume_notification)"
  echo "volume_system=$(guest_get system volume_system)"
  echo "volume_ring=$(guest_get system volume_ring)"
  echo "mode_ringer=$(guest_get system mode_ringer)"
  echo "zen_mode=$(guest_get global zen_mode)"
} > "$B/android-restore.conf"
chmod 0644 "$B/android-restore.conf"
cp -a "$B/android-restore.conf" "$B/android-restore.conf.orig"

# If we captured empty mode_ringer, settings provider may not be ready
if ! grep -q '^mode_ringer=' "$B/android-restore.conf" || \
   [ "$(sed -n 's/^mode_ringer=//p' "$B/android-restore.conf")" = "" ]; then
  echo "ERROR: failed to read Android settings (empty mode_ringer)" >&2
  cat "$B/android-restore.conf" >&2
  exit 4
fi

# Persistent state used by the helper's full/restore verbs
mkdir -p /var/lib/waydroid-host-stack/state
cp -a "$B/android-restore.conf" "$STATE"
chmod 0644 "$STATE"

# Rollback script (standalone)
cp rollback.sh "$B/rollback.sh"
chmod 0755 "$B/rollback.sh"

# Install files
install -D -o root -g root -m 0755 fp5-android-sound-profile.sh \
  /var/lib/waydroid-host-stack/sbin/fp5-android-sound-profile.sh
install -o root -g root -m 0644 fp5-android-sound-profile@.service \
  /etc/systemd/system/fp5-android-sound-profile@.service
install -o root -g root -m 0644 60-fp5-android-sound-profile.rules \
  /etc/polkit-1/rules.d/60-fp5-android-sound-profile.rules
install -D -o "$FP5" -g "$FP5" -m 0755 fp5-feedbackd-profile-sync \
  $FP5_HOME/.local/bin/fp5-feedbackd-profile-sync
install -D -o "$FP5" -g "$FP5" -m 0755 fp5-event-role-restore \
  $FP5_HOME/.local/bin/fp5-event-role-restore
install -D -o "$FP5" -g "$FP5" -m 0755 fp5-clocks-alarm-sound \
  $FP5_HOME/.local/bin/fp5-clocks-alarm-sound
install -D -o "$FP5" -g "$FP5" -m 0644 fp5-feedbackd-profile-sync.service \
  $FP5_HOME/.config/systemd/user/fp5-feedbackd-profile-sync.service
install -D -o "$FP5" -g "$FP5" -m 0644 fp5-clocks-alarm-sound.service \
  $FP5_HOME/.config/systemd/user/fp5-clocks-alarm-sound.service

systemctl daemon-reload
# User manager only: does not restart running units
systemctl --user -M ${FP5}@ daemon-reload

# Current feedbackd profile is expected to be silent; apply Android+event-sounds
# as root first (no polkit), then enable the watcher.
as_fp5 gsettings set org.gnome.desktop.sound event-sounds false
/var/lib/waydroid-host-stack/sbin/fp5-android-sound-profile.sh silent

systemctl --user -M ${FP5}@ enable --now fp5-feedbackd-profile-sync.service
systemctl --user -M ${FP5}@ enable --now fp5-clocks-alarm-sound.service

# Polkit self-check: can fp5 start the helper without a password?
if as_fp5 systemctl start --no-ask-password fp5-android-sound-profile@silent.service; then
  echo "polkit-start: ok"
else
  echo "WARNING: polkit start as fp5 failed; watcher may not be able to switch profiles" >&2
fi

echo "installed; backup in $B"
echo "android-restore:"
cat "$B/android-restore.conf"
echo "status:"
cat /var/lib/waydroid-host-stack/state/android-sound-profile.status 2>/dev/null || true
