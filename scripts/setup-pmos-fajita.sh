#!/bin/sh
# Deprecated: use scripts/setup-pmos.sh (per-device config in devices/).
WHS_DEVICE="${WHS_DEVICE:-oneplus-fajita}" exec sh "$(CDPATH='' cd -- "$(dirname "$0")" && pwd)/setup-pmos.sh" "$@"
