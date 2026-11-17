#!/bin/sh
# Install the password-less "Open Frunk" launcher. Run as root from this directory.
set -eu
cd "$(dirname "$0")"
B=/var/lib/fp5-backup/20261117-frunk-sensor
mkdir -p "$B/orig"
# backup: record which targets existed, copy them
: > "$B/manifest"
for f in /etc/systemd/system/tesla-frunk.service /var/lib/fp5-tesla/bin/tesla-frunk-root.sh \
         /etc/polkit-1/rules.d/60-fp5-tesla-frunk.rules /home/fp5/.local/bin/tesla-frunk; do
  if [ -e "$f" ]; then mkdir -p "$B/orig$(dirname "$f")"; cp -a "$f" "$B/orig$f"; echo "existed $f" >> "$B/manifest";
  else echo "new $f" >> "$B/manifest"; fi
done
[ -d /var/lib/fp5-tesla ] && echo "existed-dir /var/lib/fp5-tesla" >> "$B/manifest" || echo "new-dir /var/lib/fp5-tesla" >> "$B/manifest"
cp rollback.sh "$B/rollback.sh"; chmod 0755 "$B/rollback.sh"
install -D -o root -g root -m 0755 tesla-frunk-root.sh /var/lib/fp5-tesla/bin/tesla-frunk-root.sh
install -o root -g root -m 0644 tesla-frunk.service /etc/systemd/system/tesla-frunk.service
install -o root -g root -m 0644 60-fp5-tesla-frunk.rules /etc/polkit-1/rules.d/60-fp5-tesla-frunk.rules
install -o fp5 -g fp5 -m 0755 tesla-frunk /home/fp5/.local/bin/tesla-frunk
systemctl daemon-reload
echo "installed; backup in $B"
