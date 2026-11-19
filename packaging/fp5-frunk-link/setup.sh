#!/bin/sh
# FP5 Frunk link fix: on-phone installer (2026-11-19). Run ONLY with Kristian's yes, in a terminal on
# the phone as the normal user. run0 asks for the password once.
#   sh setup.sh                    install files only (active after reboot)
#   sh setup.sh --restart-bridge   also restart waydroid-bt-host now (Waydroid session restarts, ~30 s)
# Fetches files pinned to commit fbd323680778a14498190f99558b6d69e2f05a30,
# checks sha256, installs (backup + rollback under /var/lib/fp5-backup/20261119-frunk-link/).
# Output carries no addresses, numbers or names. Does not touch the car (no Frunk command).
set -eu
case "${1:-}" in ""|--restart-bridge) ;; *) echo "usage: sh setup.sh [--restart-bridge]"; exit 1 ;; esac
C=fbd323680778a14498190f99558b6d69e2f05a30
U=https://raw.githubusercontent.com/isyourbrainfoss/waydroid-host-stack/$C/packaging/fp5-frunk-link
[ "$(id -u)" = 60434 ] || echo "note: run this as the phone user fp5"
D=$(mktemp -d /tmp/frunk-link.XXXXXX)
get() {
    mkdir -p "$(dirname "$D/$1")"
    if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$D/$1" "$U/$1"
    elif command -v wget >/dev/null 2>&1; then wget -qO "$D/$1" "$U/$1"
    else python3 -c 'import sys,urllib.request as u; u.urlretrieve(sys.argv[1], sys.argv[2])' "$U/$1" "$D/$1"; fi
}
echo "== download (~5 MB)"
for f in install.sh rollback.sh SHA256SUMS files/waydroid-bt-host files/libphosh-plugin-frunk-quick-setting.so \
         files/tesla-frunk-root.sh files/tesla-frunk.service; do get "$f"; done
cd "$D"
sha256sum -c <<'SUMS' || { echo "SHA256 MISMATCH - stopped, nothing installed"; rm -rf "$D"; exit 1; }
484740d336d04664c25b5cbecf4e4030a7faa6dd7abe6f4a2e47d5184fd707a1  install.sh
73c1358a64c526a8b683f2e1e212115eca1227f07e710ab62a71869317cb4345  rollback.sh
6721b410c7279c2998638db06a49b9f6b9931b2e669571560b45d41af336c114  SHA256SUMS
ce44d0dcfd1c9cf746af0bd0a73b66446a0caae4ff25fcbf757bd3a4c1cde60a  files/libphosh-plugin-frunk-quick-setting.so
4a3f9a46593ee6429bb07c0e9f690533290fec08093fa1f11b86e34a43e9aff1  files/tesla-frunk-root.sh
3a74f8095a0bfbdcb28ecb22a63330c0f416c4363864deb16cebb7e3dc6a7f3c  files/tesla-frunk.service
c8cad8f2069b9cdf5ad5264bb1afb8f03444fd4ec25f0aa987cb05223c99a013  files/waydroid-bt-host
SUMS
echo "== install (type your password)"
run0 sh "$D/install.sh" ${1:-} "$D"
echo "== DONE. Logs after the next press:"
echo "   journalctl -b -t tesla-frunk ; journalctl -b -t phosh -g frunk-quick-setting"
echo "   journalctl -u waydroid-bt-host -b | grep -E 'handing to guest|LE link (hold|dropped)|early drop|kick'"
echo "   Rollback: run0 sh /var/lib/fp5-backup/20261119-frunk-link/rollback.sh [--restart-bridge]"
rm -rf "$D"
