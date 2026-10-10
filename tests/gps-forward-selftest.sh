#!/bin/sh
# Drives the shipped waydroid-gps-forward selftest entry point.
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/waydroid-gps-forward.sh"
test -f "$SCRIPT"
exec sh "$SCRIPT" selftest
