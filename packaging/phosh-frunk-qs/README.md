# Frunk quick setting for Phosh (FP5, BengalOS 0.26.1116.1 / phosh 0.59.0+nb20261116)

A Phosh quick-setting tile "Frunk" in the top-bar pulldown, also on the lock screen.
Tap -> `systemctl start --no-ask-password tesla-frunk.service` (polkit rule
60-fp5-tesla-frunk.rules: user fp5, local active session, start only). The root side
(tesla-frunk-root.sh) re-checks the live BLE link + Tesla notification before sending.
Result: tile label for 5 s + a notification (D-Bus Notify; notify-send is not installed).
Tile is insensitive ("Frunk (no car)") unless BlueZ shows a connected device with the
Tesla VCSEC GATT service (00000211-b2d1-...).

Phosh facts (0.59 source):
- quick-setting plugins: GIO modules in /usr/lib/aarch64-linux-gnu/phosh/plugins
  (PHOSH_PLUGINS_DIR, compiled in; no /usr/local or env override), extension point
  "phosh-quick-setting-widget", `<id>.plugin` desktop-style file next to the .so.
- the dir is scanned once when phosh starts (g_io_modules_scan_all_in_directory);
  enabling = mobi.phosh.shell.plugins quick-settings (live-reloaded, but only finds
  plugins scanned at startup) -> a new plugin needs phosh to start after it is present.
- custom quick settings are shown on the lock screen too (upstream ssh/hotspot plugins
  explicitly disable themselves when locked; this one does not, on purpose).
- /usr is read-only (erofs + sysext overlay) -> shipped as a directory sysext
  /var/lib/extensions/fp5-frunk-qs pinned to VERSION_ID=0.26.1116.1.

Install: `sh install.sh` (root) then reboot. Rollback: `sh rollback.sh` then reboot.
SECURITY: on the lock screen anyone holding the phone near the car can open the frunk
without unlocking (frunk only; no unlock/drive). Same as the Tesla app's own notification
button on Android lock screens.
