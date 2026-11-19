# feedbackd profile → Android sounds + GNOME event-sounds (FP5)

Phosh silent (`org.sigxcpu.feedbackd profile`) does not mute:

- Android / Waydroid notification sounds (mixed in `audio.primary.waydroid.so`
  and played to the host Pulse socket, bypassing feedbackd)
- The charger unplug/plug click from `gsd-power` + libcanberra, which follows
  `org.gnome.desktop.sound event-sounds` rather than feedbackd

This add-on watches the feedbackd profile and mirrors it.

## Pieces

- `fp5-feedbackd-profile-sync` (user fp5): `gsettings monitor`, sets
  `event-sounds` false in silent/quiet and true in full, starts the root
  helper, retries until Waydroid's settings provider is ready, and re-applies
  when `waydroid-session` comes back.
- `fp5-android-sound-profile@.service` + `fp5-android-sound-profile.sh`:
  root oneshot, verbs `silent` / `quiet` / `full` / `restore` only.
- `60-fp5-android-sound-profile.rules`: polkit YES only for user fp5, verb
  `start`, and those four instance names. `subject.local` / `subject.active`
  are not required so the user systemd watcher can start the helper.

## Mapping (no `zen_mode`)

- silent: `event-sounds false`; Android `charging_sounds_enabled=0`,
  `power_sounds_enabled=0`, `volume_notification=0`, `volume_system=0`,
  `volume_ring=0`, `mode_ringer=0` (SILENT). Music / alarm / voice volumes
  are left alone.
- quiet: same host and charging/notification/system mutes; `mode_ringer=1`
  (VIBRATE).
- full / restore: `event-sounds true` (host); Android values restored from
  the snapshot taken at install
  (`/var/lib/fp5-backup/20261119-sound-sync/android-restore.conf`).

`zen_mode` is read and recorded only. It is never written (DND can hide the
Tesla "Connected" notification that the frunk launcher depends on).

## Install / rollback

Install (root, from this dir): `sh install.sh`

Backup: `/var/lib/fp5-backup/20261119-sound-sync/`

Rollback: `run0 sh /var/lib/fp5-backup/20261119-sound-sync/rollback.sh --apply`
(dry-run without `--apply`)

No restarts of PipeWire, feedbackd, waydroid-session, phoc or greetd; no
reboot; no sysext refresh. polkitd reloads rules by itself.
