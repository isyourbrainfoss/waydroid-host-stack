#!/bin/sh
# /var/lib/fp5-tesla/bin/tesla-frunk-root.sh (root:root 0755), run by tesla-frunk.service.
# Fires the same intent as the Tesla phone-key notification's "Front Trunk" button
# (PendingIntent requestCode=14: com.teslamotors.ble.action.COMMAND -> PhoneKeyCommandReceiver),
# but ONLY if that notification says "Connected" and offers "Front Trunk".
# Exit 0 = sent, 3 = car not connected, 4 = Waydroid not running, 5 = send failed.
# Test mode (never sends anything):  tesla-frunk-root.sh --check-only [dumpsys-file]
# Prints nothing sensitive; the dumpsys output never leaves this pipeline.
set -u
LXCP=/var/lib/waydroid/lxc
lxc_sh() { lxc-attach -P "$LXCP" -n waydroid --clear-env -- /system/bin/sh -c "export PATH=/system/bin; $1"; }

key_state() {   # stdin: `dumpsys notification --noredact`; stdout: ok | nobutton | notconnected
  awk '
    /^  Snoozed notifications:/ { exit }   # only the live "Notification List"
    /NotificationRecord\(/ { inrec = ($0 ~ /pkg=com\.teslamotors\.tesla / && $0 ~ /phone_key_service_channel/) }
    inrec && /"Front Trunk"/ { ft = 1 }
    inrec && /android\.text=String \(Connected\)/ { c = 1 }
    END { if (c && ft) print "ok"; else if (c) print "nobutton"; else print "notconnected" }'
}

if [ "${1:-}" = "--check-only" ]; then
  if [ -n "${2:-}" ]; then key_state < "$2"; else lxc_sh 'dumpsys notification --noredact' 2>/dev/null | key_state; fi
  exit 0
fi

lxc-info -P "$LXCP" -n waydroid -s 2>/dev/null | grep -q RUNNING || { echo "waydroid not running"; exit 4; }
state=$(lxc_sh 'dumpsys notification --noredact' 2>/dev/null | key_state)
case "$state" in
  ok) ;;
  nobutton) echo "connected but no Front Trunk action"; exit 3 ;;
  *) echo "car not connected"; exit 3 ;;
esac
if lxc_sh 'am broadcast -a com.teslamotors.ble.action.COMMAND -n com.teslamotors.tesla/com.teslamotors.plugins.ble.PhoneKeyCommandReceiver --ei command_id 14' 2>/dev/null | grep -q 'result=0'; then
  echo "sent"; exit 0
fi
echo "send failed"; exit 5
