#!/bin/sh
# Install + rollback dry test in a fake root (no root, no systemd, nothing on the phone).
# Needs the 19 Nov reference files: REF=/path/with/waydroid-bt-host+libphosh-plugin-frunk-quick-setting.so
# and the original tesla-frunk-root.sh/.service from git (origin/main).
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
REF=${REF:?}
T=$(mktemp -d); export FP5_TEST_ROOT="$T/root"; R=$FP5_TEST_ROOT
mkdir -p "$T/bin" "$R/etc/systemd/system" "$R/var/lib/waydroid-host-stack/bin" "$R/var/lib/fp5-tesla/bin" "$R/run/waydroid-bt"
printf '#!/bin/sh\ncase "$*" in *is-active*) exit 3;; *MainPID*) echo 0;; esac\nexit 0\n' > "$T/bin/systemctl"; chmod +x "$T/bin/systemctl"
PATH="$T/bin:$PATH"
echo VERSION_ID=0.26.1117.1 > "$R/etc/os-release"
cp "$REF/waydroid-bt-host" "$R/var/lib/waydroid-host-stack/bin/"
git -C "$HERE" show d9a316e:packaging/tesla-frunk/tesla-frunk-root.sh > "$R/var/lib/fp5-tesla/bin/tesla-frunk-root.sh"
git -C "$HERE" show d9a316e:packaging/tesla-frunk/tesla-frunk.service > "$R/etc/systemd/system/tesla-frunk.service"
for d in fp5-frunk-qs fp5-frunk-qs_0.26.1117.1; do
  mkdir -p "$R/var/lib/extensions/$d/usr/lib/aarch64-linux-gnu/phosh/plugins"
  cp "$REF/libphosh-plugin-frunk-quick-setting.so" "$R/var/lib/extensions/$d/usr/lib/aarch64-linux-gnu/phosh/plugins/"
done
before=$(cd "$R" && find . -type f | sort | xargs sha256sum)
fail=0
sh "$HERE/install.sh" "$HERE" | sed "s|$R||g"
echo "-- after install, files equal bundle?"
for f in var/lib/waydroid-host-stack/bin/waydroid-bt-host:waydroid-bt-host var/lib/fp5-tesla/bin/tesla-frunk-root.sh:tesla-frunk-root.sh \
         etc/systemd/system/tesla-frunk.service:tesla-frunk.service \
         var/lib/extensions/fp5-frunk-qs/usr/lib/aarch64-linux-gnu/phosh/plugins/libphosh-plugin-frunk-quick-setting.so:libphosh-plugin-frunk-quick-setting.so \
         var/lib/extensions/fp5-frunk-qs_0.26.1117.1/usr/lib/aarch64-linux-gnu/phosh/plugins/libphosh-plugin-frunk-quick-setting.so:libphosh-plugin-frunk-quick-setting.so; do
  cmp -s "$R/${f%%:*}" "$HERE/files/${f##*:}" && echo "ok ${f%%:*}" || { echo "FAIL ${f%%:*}"; fail=1; }
done
echo "-- second install must refuse"
if sh "$HERE/install.sh" "$HERE" >/dev/null 2>&1; then echo FAIL; fail=1; else echo "ok refused"; fi
echo "-- rollback"
sh "$R/var/lib/fp5-backup/20261119-frunk-link/rollback.sh" | sed "s|$R||g"
after=$(cd "$R" && find . -type f -not -path './var/lib/fp5-backup/*' | sort | xargs sha256sum)
[ "$before" = "$after" ] && echo "ok rollback restores byte-identical files" || { echo "FAIL rollback differs"; fail=1; }
echo "-- install refuses when a target differs"
echo junk >> "$R/var/lib/fp5-tesla/bin/tesla-frunk-root.sh"
if sh "$HERE/install.sh" "$HERE" >/dev/null 2>&1; then echo FAIL; fail=1; else echo "ok refused"; fi
rm -rf "$T"; [ $fail = 0 ] && echo "install-test: PASS" || { echo "install-test: FAIL"; exit 1; }
