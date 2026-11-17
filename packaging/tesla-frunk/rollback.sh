#!/bin/sh
# Roll back the Open Frunk launcher install. Dry-run unless --apply.
set -eu
B=/var/lib/fp5-backup/20261117-frunk-sensor
A=${1:-}
run() { if [ "$A" = --apply ]; then "$@"; else echo "would: $*"; fi; }
while read -r kind f; do
  case "$kind" in
    existed) run cp -a "$B/orig$f" "$f" ;;
    new) run rm -f "$f" ;;
    new-dir) run rm -rf "$f" ;;
  esac
done < "$B/manifest"
run systemctl daemon-reload
