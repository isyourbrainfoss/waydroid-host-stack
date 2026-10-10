#!/bin/sh
# Nura "Duranium" / other image-based hosts: thin wrapper that forces the
# immutable layout (PREFIX=/var/lib/waydroid-host-stack, UNITDIR=/etc/systemd/system).
# Usage: sudo sh scripts/install-duranium.sh [install-host-system.sh args]
set -eu
FORCE_IMMUTABLE=1 exec sh "$(CDPATH='' cd -- "$(dirname "$0")" && pwd)/install-host-system.sh" "$@"
