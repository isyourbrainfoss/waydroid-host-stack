#!/bin/sh
# Drives the shipped waydroid-nfc-forward selftest entry point (no theater).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/waydroid-nfc-forward.sh"
test -x "$SCRIPT" || chmod +x "$SCRIPT"
exec sh "$SCRIPT" selftest
