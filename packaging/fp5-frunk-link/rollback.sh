#!/bin/sh
# Roll back the 2026-11-19 Frunk link fix:  run0 sh /var/lib/fp5-backup/20261119-frunk-link/rollback.sh [--restart-bridge]
set -eu
R=${FP5_TEST_ROOT:-}   # tests only: fake root prefix
BK=$R/var/lib/fp5-backup/20261119-frunk-link
[ "$(id -u)" = 0 ] || [ -n "$R" ] || { echo "run as root" >&2; exit 1; }
[ -f "$BK/manifest" ] || { echo "no manifest in $BK" >&2; exit 1; }
while read -r f; do
  [ -n "$f" ] || continue
  cp -a "$BK/orig$f" "$f.rb-frunk-link" && mv -f "$f.rb-frunk-link" "$f"
  echo "restored $f"
done < "$BK/manifest"
systemctl daemon-reload
rm -f $R/run/waydroid-bt/features
if [ "${1:-}" = "--restart-bridge" ]; then
  systemctl restart waydroid-bt-host.service; echo "bridge restarted (Waydroid session restarts via drop-in)"
else
  echo "old bridge active after reboot or 'run0 systemctl restart waydroid-bt-host'; old tile after reboot"
fi
mv "$BK" "$BK.rolledback-$(date +%Y%m%d%H%M%S)"
echo "FRUNK_LINK_ROLLBACK_OK"
