#!/bin/sh
# Install (or remove) Waydroid overlay so guest full-boots despite host
# kernel cmdline containing androidboot.mode=charger (OnePlus bootloader).
#
# Root cause: host /proc/cmdline has both androidboot.mode=charger (first)
# and androidboot.mode=normal (later). Android init takes the first → charger
# class only → no zygote → IP UNKNOWN forever (classic “half-boot” on fajita).
#
# Fix: overlay init.rc fragment that on `charger` also starts main/late_start
# and triggers normal boot actions.
#
# Usage:
#   waydroid-force-normal-boot install   # default
#   waydroid-force-normal-boot status
#   waydroid-force-normal-boot remove
#   waydroid-force-normal-boot --selftest
set -eu

OVERLAY_DIR=/var/lib/waydroid/overlay/system/etc/init
RC_NAME=waydroid_force_normal_boot.rc
RC_PATH="$OVERLAY_DIR/$RC_NAME"

RC_BODY='# Force full Android boot when host kernel cmdline has androidboot.mode=charger
# (OnePlus bootloader injects charger; pmOS also has androidboot.mode=normal later).
# Without this, init only starts the charger class and never zygote/system_server.
# Installed by waydroid-force-normal-boot (waydroid-bluetooth).

on charger
    class_start main
    class_start late_start
    trigger late-init
    trigger boot
    trigger nonencrypted
    trigger post-fs-data
    trigger zygote-start
'

cmd=${1:-install}

selftest() {
  fail=0
  me=$(readlink -f "$0" 2>/dev/null || echo "$0")
  grep -q 'on charger' "$me" || { echo "FAIL missing on charger"; fail=1; }
  grep -q 'class_start main' "$me" || { echo "FAIL missing class_start main"; fail=1; }
  grep -q 'trigger zygote-start' "$me" || { echo "FAIL missing zygote-start"; fail=1; }
  if [ "$fail" -ne 0 ]; then
    echo "FORCE_NORMAL_BOOT_SELFTEST_FAILED"
    return 1
  fi
  echo "ALL_FORCE_NORMAL_BOOT_SELFTESTS_OK"
  return 0
}

case "$cmd" in
  --selftest) selftest; exit $? ;;
  -h|--help)
    echo "Usage: waydroid-force-normal-boot [install|status|remove|--selftest]"
    exit 0
    ;;
  status)
    if [ -f "$RC_PATH" ]; then
      echo "FORCE_NORMAL_BOOT installed: $RC_PATH"
      # host cmdline hint
      if grep -q 'androidboot.mode=charger' /proc/cmdline 2>/dev/null; then
        echo "host_cmdline: androidboot.mode=charger present (overlay needed)"
      else
        echo "host_cmdline: no androidboot.mode=charger"
      fi
      exit 0
    fi
    echo "FORCE_NORMAL_BOOT not installed"
    exit 1
    ;;
  remove)
    if [ -f "$RC_PATH" ]; then
      sudo -n rm -f "$RC_PATH"
      echo "FORCE_NORMAL_BOOT removed $RC_PATH"
      echo "Restart Waydroid session for change to apply"
    else
      echo "FORCE_NORMAL_BOOT already absent"
    fi
    exit 0
    ;;
  install)
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    exit 2
    ;;
esac

if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
  echo "need passwordless sudo to write $OVERLAY_DIR" >&2
  exit 1
fi

sudo -n mkdir -p "$OVERLAY_DIR"
# Write atomically
tmp=$(mktemp)
printf '%s\n' "$RC_BODY" >"$tmp"
sudo -n install -m 0644 "$tmp" "$RC_PATH"
rm -f "$tmp"

echo "FORCE_NORMAL_BOOT_INSTALLED $RC_PATH"
if grep -q 'androidboot.mode=charger' /proc/cmdline 2>/dev/null; then
  echo "host has androidboot.mode=charger — overlay required for full Waydroid boot"
fi
echo "Restart Waydroid (waydroid-half-boot-fix --force) if session already running"
