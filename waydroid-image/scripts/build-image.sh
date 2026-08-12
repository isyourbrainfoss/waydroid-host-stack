#!/usr/bin/env bash
# Outline helper for custom Waydroid images with Bluetooth restored.
# This does NOT replace a full AOSP/Lineage build environment.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
echo "waydroid-bluetooth image helper"
echo "repo root: $ROOT"
echo
echo "Steps (manual / CI):"
echo "  1. Prepare Lineage/Waydroid build tree per docs.waydro.id"
echo "  2. Apply guidance in waydroid-image/patches/"
echo "  3. Copy guest/{hal,sepolicy,init} into the product/vendor tree"
echo "  4. lunch <waydroid_target>"
echo "  5. mka systemimage vendorimage  # names vary by version"
echo "  6. Convert sparse images if required; install on device"
echo
echo "See docs/image-build.md for details."
exit 0
