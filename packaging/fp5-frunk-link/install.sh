#!/bin/sh
# FP5 Frunk link fix (2026-11-19): bridge hand-over/early-drop reconnect + Frunk tile "Connecting…".
# Run as root ONLY with Kristian's yes:   run0 sh install.sh [--restart-bridge] [DIR]
# What it does
#   * backs up the 4 targets to /var/lib/fp5-backup/20261119-frunk-link/ (+ rollback.sh)
#   * replaces (atomically, same paths):
#       /var/lib/waydroid-host-stack/bin/waydroid-bt-host
#       /var/lib/fp5-tesla/bin/tesla-frunk-root.sh
#       /etc/systemd/system/tesla-frunk.service            (+ systemctl daemon-reload)
#       /var/lib/extensions/fp5-frunk-qs*/usr/lib/aarch64-linux-gnu/phosh/plugins/libphosh-plugin-frunk-quick-setting.so
#   * does NOT run systemd-sysext refresh, does NOT restart phosh, waydroid, bluetooth or anything else.
#   * --restart-bridge: also `systemctl restart waydroid-bt-host` (its 60-session-restart drop-in then
#     restarts the Waydroid session, ~20-40 s without Android). Without it the new bridge starts at
#     the next reboot / bridge restart.
# The new tile is loaded when phosh starts (next reboot or re-login). The new root script works with
# the OLD bridge too (it only sends SIGUSR1 if /run/waydroid-bt/features names the running PID).
set -eu
R=${FP5_TEST_ROOT:-}   # tests only: fake root prefix
RESTART=0
[ "${1:-}" = "--restart-bridge" ] && { RESTART=1; shift; }
HERE=${1:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}
BK=$R/var/lib/fp5-backup/20261119-frunk-link
BIN=$R/var/lib/waydroid-host-stack/bin/waydroid-bt-host
ROOTSH=$R/var/lib/fp5-tesla/bin/tesla-frunk-root.sh
UNIT=$R/etc/systemd/system/tesla-frunk.service
PLUG=usr/lib/aarch64-linux-gnu/phosh/plugins/libphosh-plugin-frunk-quick-setting.so
# what is installed today (19 Nov, read on the phone): refuse if something else is there
OLD_BIN=fe2c2f0bdba430b87cb704c360b8efd0f3a635557c241262e919019144859b56
OLD_ROOTSH=efcd99ee6372491069c577b54f492056aa4c2203d5b32657b11552b190b0b2f1
OLD_UNIT=d1b1bab9ca764f3b48032f548be79c23a29912cdfd8da6fb3755e4d02a1fdca0
OLD_PLUG=806df1aef18ecb79d54fda6471e5a1b866abcd8a25cbe2ebb0afe568ca555d66

[ "$(id -u)" = 0 ] || [ -n "$R" ] || { echo "run as root (run0 sh install.sh)" >&2; exit 1; }
cd "$HERE"
sha256sum -c SHA256SUMS >/dev/null || { echo "bundle sha256 mismatch - nothing installed" >&2; exit 1; }
grep -q '^VERSION_ID=0.26.1117.1$' $R/etc/os-release || { echo "OS is not BengalOS 0.26.1117.1 - re-check first" >&2; exit 1; }
[ -e "$BK/manifest" ] && { echo "backup exists already ($BK) - installed before? rollback first" >&2; exit 1; }
sum() { sha256sum "$1" | cut -d' ' -f1; }
ok=1
[ "$(sum $BIN)" = $OLD_BIN ] || { echo "unexpected $BIN" >&2; ok=0; }
[ "$(sum $ROOTSH)" = $OLD_ROOTSH ] || { echo "unexpected $ROOTSH" >&2; ok=0; }
[ "$(sum $UNIT)" = $OLD_UNIT ] || { echo "unexpected $UNIT" >&2; ok=0; }
PLUGS=""
for d in $R/var/lib/extensions/fp5-frunk-qs*; do
  [ -f "$d/$PLUG" ] || continue
  [ "$(sum "$d/$PLUG")" = $OLD_PLUG ] || { echo "unexpected $d/$PLUG" >&2; ok=0; }
  PLUGS="$PLUGS $d/$PLUG"
done
[ -n "$PLUGS" ] || { echo "Frunk tile sysext not found" >&2; ok=0; }
[ $ok = 1 ] || { echo "installed files differ from 19 Nov - nothing installed" >&2; exit 1; }
systemctl is-active -q tesla-frunk.service && { echo "a Frunk press is running - try again in 30 s" >&2; exit 1; }

echo "== backup -> $BK"
mkdir -p "$BK/orig"; chmod 700 "$BK"
: > "$BK/manifest.tmp"
for f in $BIN $ROOTSH $UNIT $PLUGS; do
  mkdir -p "$BK/orig$(dirname "$f")"; cp -a "$f" "$BK/orig$f"; echo "$f" >> "$BK/manifest.tmp"
done
cp rollback.sh "$BK/rollback.sh"; chmod 755 "$BK/rollback.sh"
mv "$BK/manifest.tmp" "$BK/manifest"

OWN="-o root -g root"; [ -z "$R" ] || OWN=""
put() { # src dst mode  (atomic replace; running binaries/mapped .so keep the old inode)
  install $OWN -m "$3" "$1" "$2.new-frunk-link" && mv -f "$2.new-frunk-link" "$2"
}
echo "== install"
put files/waydroid-bt-host "$BIN" 0755
put files/tesla-frunk-root.sh "$ROOTSH" 0755
put files/tesla-frunk.service "$UNIT" 0644
for p in $PLUGS; do put files/libphosh-plugin-frunk-quick-setting.so "$p" 0644; done
systemctl daemon-reload
echo "== verify"
for f in $BIN $ROOTSH $UNIT $PLUGS; do printf '%s  %s\n' "$(sum "$f" | cut -c1-12)" "$f"; done
if [ $RESTART = 1 ]; then
  echo "== restart waydroid-bt-host (Waydroid session restarts via drop-in)"
  systemctl restart waydroid-bt-host.service
  sleep 3
  pid=$(systemctl show -p MainPID --value waydroid-bt-host.service)
  grep -q "pid=$pid\$" $R/run/waydroid-bt/features 2>/dev/null && echo "bridge: new (kick supported)" || echo "bridge: features file not seen yet - check: journalctl -u waydroid-bt-host -n 30"
else
  echo "bridge: new binary on disk; active after the next reboot or 'run0 systemctl restart waydroid-bt-host'"
fi
echo "tile: new plugin on disk; active after the next reboot (or log out/in of phosh)"
echo "FRUNK_LINK_INSTALL_OK  rollback: run0 sh $BK/rollback.sh"
