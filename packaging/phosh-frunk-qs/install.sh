#!/bin/sh
# Install the Frunk quick setting (Phosh) as a directory sysext. Run as root ONLY with Kristian's yes:
#   run0 --no-ask-password sh install.sh
# Takes effect at the NEXT REBOOT (systemd-sysext merges before phosh starts; phosh scans its
# plugin dir only at startup). Does NOT run systemd-sysext refresh and does NOT restart phosh.
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
BK=/var/lib/fp5-backup/20261117-frunk-qs
EXT=/var/lib/extensions/fp5-frunk-qs
DESK=/home/fp5/.local/share/applications/tesla-frunk.desktop
U="run0 --no-ask-password -u fp5 env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/60434/bus"
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
cd "$HERE"; sha256sum -c SHA256SUMS
[ -e "$EXT" ] && { echo "$EXT exists already" >&2; exit 1; }
[ -e "$BK/quick-settings.orig" ] && { echo "backup exists already: $BK" >&2; exit 1; }
[ -f /var/lib/fp5-tesla/bin/tesla-frunk-root.sh ] || { echo "tesla-frunk launcher not installed" >&2; exit 1; }
grep -q '^VERSION_ID=0.26.1116.1$' /etc/os-release || { echo "OS is not 0.26.1116.1 - rebuild/re-pin first" >&2; exit 1; }
mkdir -p "$BK"; chmod 700 "$BK"
cp -a rollback.sh "$BK/rollback.sh"; chmod 755 "$BK/rollback.sh"
$U gsettings get mobi.phosh.shell.plugins quick-settings > "$BK/quick-settings.orig"
[ -f "$DESK" ] && cp -a "$DESK" "$BK/tesla-frunk.desktop.orig"
# 1) the sysext (directory form)
mkdir -p "$EXT.new/usr/lib/extension-release.d" "$EXT.new/usr/lib/aarch64-linux-gnu/phosh/plugins" \
         "$EXT.new/usr/share/fp5-frunk-qs/icons"
install -m0644 extension-release.fp5-frunk-qs "$EXT.new/usr/lib/extension-release.d/extension-release.fp5-frunk-qs"
install -m0644 libphosh-plugin-frunk-quick-setting.so "$EXT.new/usr/lib/aarch64-linux-gnu/phosh/plugins/"
install -m0644 frunk-quick-setting.plugin "$EXT.new/usr/lib/aarch64-linux-gnu/phosh/plugins/"
install -m0644 tesla-frunk-symbolic.svg "$EXT.new/usr/share/fp5-frunk-qs/icons/"
mv "$EXT.new" "$EXT"
# 2) enable the tile (append; harmless until the plugin is merged: phosh logs "not found")
cur=$(cat "$BK/quick-settings.orig")
case "$cur" in *frunk-quick-setting*) ;; *)
  new=$(printf '%s' "$cur" | sed -E "s/^@as \[\]$/[]/; s/\]$/, 'frunk-quick-setting']/; s/^\[, /[/")
  $U gsettings set mobi.phosh.shell.plugins quick-settings "$new" ;;
esac
# 3) hide the app-drawer icon (kept, NoDisplay=true)
if [ -f "$DESK" ] && ! grep -q '^NoDisplay=true' "$DESK"; then
  printf 'NoDisplay=true\n' >> "$DESK"
fi
echo "FRUNK_QS_INSTALL_OK - active after the next reboot. Rollback: run0 --no-ask-password sh $BK/rollback.sh"
