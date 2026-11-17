# Open Frunk without a password (FP5, 17 Nov 2026)

The Phosh "Open Frunk" icon (`~/.local/share/applications/tesla-frunk.desktop`, unchanged) runs
`~/.local/bin/tesla-frunk`. The old script used `run0 lxc-attach ...`, which needs polkit
`org.freedesktop.systemd1.manage-units` and therefore asked fp5 for a password. It also never
checked whether the car was connected.

New design:
- `tesla-frunk` (user fp5): `systemctl start --no-ask-password tesla-frunk.service`, then a
  notification: sent / car not connected / Waydroid not running / could not send.
- `60-fp5-tesla-frunk.rules`: polkit YES only for user fp5, local+active session, unit
  `tesla-frunk.service`, verb `start`. Nothing else.
- `tesla-frunk.service`: root oneshot, fixed command, no arguments, max 3 starts / 30 s, 20 s timeout.
- `tesla-frunk-root.sh`: reads the Tesla phone-key notification inside Waydroid; only if it says
  "Connected" and offers "Front Trunk" does it send the same intent as that button
  (requestCode 14 -> `com.teslamotors.ble.action.COMMAND` -> PhoneKeyCommandReceiver, command_id 14).
  Since 17 Nov (link-loss fix): it ALSO requires BlueZ to show a live LE link to the device
  carrying the Tesla VCSEC GATT service (00000211-b2d1-...), because the notification could
  stay "Connected" after the link was lost. Exit 3 when not connected. `--check-only [file]` evaluates the state without sending anything.

Install (root, from this dir): `sh install.sh`  (backs up to /var/lib/fp5-backup/20261117-frunk-sensor/)
Verify (read-only, never starts the unit): `sh verify.sh`
Rollback: `sh /var/lib/fp5-backup/20261117-frunk-sensor/rollback.sh --apply` (dry-run without --apply)
No restarts of bluetooth/dbus/greetd/phoc/waydroid. polkitd reloads rules by itself.
