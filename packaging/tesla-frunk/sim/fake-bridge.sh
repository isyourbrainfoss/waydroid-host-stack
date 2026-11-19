#!/bin/sh
# fake waydroid-bt-host: on SIGUSR1 bring the "car link" up after $1 s (or never if "never")
trap 'echo kicked >> "$SIM/kicks"; [ "$1" = never ] || (sleep "$1"; touch "$SIM/link_up") &' USR1
while :; do sleep 0.1; done
