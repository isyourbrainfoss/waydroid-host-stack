#!/bin/sh
# Host NFC diagnostic for OnePlus 6/6T (pmOS) based on wiki notes.
# Wiki: NFC “works” after DTB enablement; userspace stock libnfc is NOT enough
# (needs NXP libnfc-nci). neard uses kernel NFC netlink.
#
# Usage: nfc-host-diag [--poll-seconds N]
set -eu
POLL_S=8
case "${1:-}" in
  --poll-seconds) POLL_S="${2:-8}" ;;
  -h|--help) echo "Usage: $0 [--poll-seconds N]"; exit 0 ;;
esac

echo "# NFC host diagnostic"
echo "time=$(date -Is 2>/dev/null || date)"
echo "host=$(hostname 2>/dev/null || true)"
echo "uname=$(uname -a)"
echo
echo "## Wiki expectation (OP6/enchilada)"
echo "- Kernel/DT: enable I2C + NFC GPIOs (NFC.patch style status=okay)"
echo "- Stock Alpine libnfc (USB PN53x) will report 'No NFC device' — expected"
echo "- Prefer neard + kernel NCI (nxp_nci_i2c) for host tags"
echo "- libnfc-nci (NXP) not packaged on Alpine; Soft NFC HAL out of scope"
echo

echo "## Kernel modules"
lsmod 2>/dev/null | grep -iE 'nfc|nci|nxp' || echo "(none matching)"
echo

echo "## sysfs"
if [ -e /sys/class/nfc/nfc0 ]; then
  echo "nfc0: present"
  cat /sys/class/nfc/nfc0/device/uevent 2>/dev/null || true
  if [ -f /sys/class/nfc/nfc0/rfkill0/state ]; then
    echo "rfkill_state=$(cat /sys/class/nfc/nfc0/rfkill0/state)"
    echo "rfkill_soft=$(cat /sys/class/nfc/nfc0/rfkill0/soft 2>/dev/null || true)"
    echo "rfkill_hard=$(cat /sys/class/nfc/nfc0/rfkill0/hard 2>/dev/null || true)"
  fi
else
  echo "nfc0: MISSING — DTB/NFC driver not up (see wiki NFC.patch)"
fi
echo

echo "## neard"
systemctl is-active neard 2>/dev/null || echo "neard: inactive"
if busctl list 2>/dev/null | grep -q org.neard; then
  busctl set-property org.neard /org/neard/nfc0 org.neard.Adapter Powered b true 2>/dev/null || true
  busctl call org.neard /org/neard/nfc0 org.neard.Adapter StopPollLoop 2>/dev/null || true
  sleep 1
  busctl call org.neard /org/neard/nfc0 org.neard.Adapter StartPollLoop s Initiator 2>/dev/null \
    || busctl call org.neard /org/neard/nfc0 org.neard.Adapter StartPollLoop s Dual 2>/dev/null \
    || true
  i=0
  while [ "$i" -lt "$POLL_S" ]; do
    powered=$(busctl get-property org.neard /org/neard/nfc0 org.neard.Adapter Powered 2>/dev/null || true)
    polling=$(busctl get-property org.neard /org/neard/nfc0 org.neard.Adapter Polling 2>/dev/null || true)
    mode=$(busctl get-property org.neard /org/neard/nfc0 org.neard.Adapter Mode 2>/dev/null || true)
    echo "t=${i}s powered=$powered polling=$polling mode=$mode"
    if busctl call org.neard / org.freedesktop.DBus.ObjectManager GetManagedObjects 2>/dev/null \
      | grep -q org.neard.Tag; then
      echo "TAG_OBJECT_SEEN"
      busctl call org.neard / org.freedesktop.DBus.ObjectManager GetManagedObjects 2>/dev/null | head -c 4000
      echo
      break
    fi
    i=$((i + 1))
    sleep 1
  done
  if ! busctl call org.neard / org.freedesktop.DBus.ObjectManager GetManagedObjects 2>/dev/null \
    | grep -q org.neard.Tag; then
    echo "NO_TAG_OBJECT after ${POLL_S}s poll (card present? RF path?)"
  fi
else
  echo "org.neard not on bus"
fi
echo

echo "## stock libnfc (expected fail on kernel NCI)"
if command -v nfc-list >/dev/null 2>&1; then
  nfc-list 2>&1 | head -15
else
  echo "nfc-list not installed"
fi
echo

echo "## dmesg (nfc)"
dmesg 2>/dev/null | grep -iE 'nfc|nci|pn5|nxp' | tail -30 || echo "(empty)"
echo
echo "NFC_HOST_DIAG_DONE"
