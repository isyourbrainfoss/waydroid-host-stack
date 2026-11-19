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

## Live AudioService (19 Nov 2026 follow-up)

`settings put system volume_*` and `mode_ringer` are persisted but Android 13's
AudioService does not apply them live (they are loaded at boot). This image
also has no `cmd audio set-ringer-mode` (only surround-format commands).

The helper now changes live state:

- ringer: `service call audio 40` (`setRingerModeExternal`; codes from this
  image's `IAudioService$Stub`). 0=SILENT, 1=VIBRATE, 2=NORMAL.
- stream volumes: `cmd media_session volume --stream N --set/--get`, verified
  (and fallen back) with `service call audio 135/177`. Streams 5
  (NOTIFICATION), 1 (SYSTEM) and 2 (RING) only. Music/alarm/voice are left
  alone. On Android 13, NOTIFICATION is often aliased to RING.
- charging/power sound Settings keys are still written; `charging_sounds_enabled`
  is read live by the charging-sound code.

Update on a phone that already has v1: as root, from this dir,
`sh update-live.sh` (backs up the v1 helper, saves live restore values, applies silent).

## System / event sounds (USB plug-unplug)

`org.gnome.desktop.sound event-sounds=false` does not stop `gsd-power`'s
libcanberra `power-plug` / `power-unplug` clicks on Phosh (no XSettings).
Those streams have `media.role=event` and
`module-stream-restore.id=sink-input-by-media-role:event`.

The user watcher also mutes that Pulse ext-stream-restore entry in silent and
quiet (and restores the saved mute/volume in full) via
`~/.local/bin/fp5-event-role-restore`. No root, no PipeWire/WirePlumber
restart. The original value is saved in
`~/.local/state/fp5-sound-sync/event-role-restore.conf`.
`ExecStop` and `rollback.sh` restore it. Alarm/ringtone feedbackd sounds use
`media-role` Alarm/Ringtone, not `event`.

## GNOME Clocks alarms on silent

Alarms must sound even in silent (Android/Phosh behaviour). GNOME Clocks
rings only via libfeedback (`alarm-clock-elapsed`, `important=true`, loop);
it does not fall back to Gtk.MediaFile and does not retry another D-Bus
signature. `org.gnome.clocks` (the GApplication / desktop id; lowercase c)
is already in `allow-important`, which is how feedbackd is supposed to play
the full-profile Sound (`media-role` Alarm) even when the global profile is
silent. The USB event-role mute does not apply to that role.

TriggerFeedback was working earlier (Clocks only logs failures; the 07:00
alarm today left no error, and feedbackd accepted numeric event ids on
previous days). From 14:58 today the method is advertised in introspection
(`ssa{sv}i`) but every call — official signature, older `ssa{sv}` /
`sa{sv}i`, and `fbcli` — returns `UnknownMethod` and no event id.
`EndFeedback` and `Haptic.Vibrate` still work. Phosh `button-pressed` and
Clocks timers from 15:37 on fail the same way, including in full profile.

Until that D-Bus method works again, the user unit
`fp5-clocks-alarm-sound.service` watches Clocks `ring_time` and plays the
alarm file with `media.role=Alarm`. It stays idle once two consecutive
TriggerFeedback probes return an id, so a later fix does not double-ring
in full. No root, no feedbackd restart. `rollback.sh` disables the unit.
