#!/bin/sh
# Read-only verification. Never starts tesla-frunk.service, never sends anything to the Tesla app.
set -u
U=fp5
echo "== files"; ls -l /etc/systemd/system/tesla-frunk.service /var/lib/fp5-tesla/bin/tesla-frunk-root.sh /etc/polkit-1/rules.d/60-fp5-tesla-frunk.rules /home/fp5/.local/bin/tesla-frunk
echo "== unit"; systemctl cat tesla-frunk.service >/dev/null && echo "systemctl cat OK"; systemd-analyze verify tesla-frunk.service 2>&1 | grep -v "^$" || echo "systemd-analyze verify: clean"
systemctl show -p ActiveState,NRestarts,ExecMainStatus tesla-frunk.service
echo "== polkit load errors since install"; journalctl -u polkit --since "-10min" --no-pager -o cat | grep -iE "error|rules|60-fp5" || echo "(none)"
# authorization checks against fp5's phosh process (pkcheck only asks polkit; nothing is started)
P=$(pgrep -u $U -x phosh | head -1)
chk() { pkcheck --action-id org.freedesktop.systemd1.manage-units --process "$P" --detail unit "$1" --detail verb "$2" >/dev/null 2>&1; echo "pkcheck unit=$1 verb=$2 -> exit $? (0=allowed)"; }
chk tesla-frunk.service start
chk tesla-frunk.service restart
chk tesla-frunk.service stop
chk bluetooth.service start
echo "== key-state parser (check-only, no send)"
echo "live: $(/var/lib/fp5-tesla/bin/tesla-frunk-root.sh --check-only)  (both must be ok/up before anything is sent)"
T=$(mktemp); printf '  Notification List:\n    NotificationRecord(0x1: pkg=com.teslamotors.tesla user=UserHandle{0} id=333 Notification(channel=phone_key_service_channel_v2 actions=3))\n                [1] "Front Trunk" -> PendingIntent{x}\n                android.text=String (Disconnected)\n  Snoozed notifications:\n                android.text=String (Connected)\n' > "$T"
echo "synthetic disconnected: $(/var/lib/fp5-tesla/bin/tesla-frunk-root.sh --check-only "$T") (expect notconnected)"
printf '  Notification List:\n  Snoozed notifications:\n' > "$T"
echo "synthetic no-notification: $(/var/lib/fp5-tesla/bin/tesla-frunk-root.sh --check-only "$T") (expect notconnected)"
rm -f "$T"
