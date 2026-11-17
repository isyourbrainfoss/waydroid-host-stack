#!/bin/sh
# Remove the Frunk quick setting. run0 --no-ask-password sh /var/lib/fp5-backup/20261117-frunk-qs/rollback.sh
# Fully gone after the next reboot (or a systemd-sysext refresh + phosh restart, only with Kristian's yes).
# Emergency (phosh crash-loops after reboot): run this over ssh as fp5ops, then reboot.
set -u
BK=/var/lib/fp5-backup/20261117-frunk-qs
EXT=/var/lib/extensions/fp5-frunk-qs
DESK=/home/fp5/.local/share/applications/tesla-frunk.desktop
U="runuser -u fp5 -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/60434/bus"
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
if [ -f "$BK/quick-settings.orig" ]; then
  $U gsettings set mobi.phosh.shell.plugins quick-settings "$(cat "$BK/quick-settings.orig")" \
    || echo "gsettings restore failed (no session bus?) - set it by hand: $(cat "$BK/quick-settings.orig")"
fi
rm -rf "$EXT" "$EXT.new"
[ -f "$BK/tesla-frunk.desktop.orig" ] && cp -a "$BK/tesla-frunk.desktop.orig" "$DESK"
echo "FRUNK_QS_ROLLBACK_OK (plugin unmerged at the next reboot)"
