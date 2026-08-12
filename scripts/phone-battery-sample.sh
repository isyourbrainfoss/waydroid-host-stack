#!/bin/sh
# Sample battery capacity over short windows for idle vs field-ready postures.
#
# Usage:
#   phone-battery-sample [seconds_per_phase] [interval]
# Defaults: 45s per phase, sample every 5s.
# Writes report to stdout (redirect to file for evidence).
set -eu

# Accept only numeric duration/interval (ignore accidental labels like "idle")
PHASE_S=45
INTERVAL=5
if [ -n "${1:-}" ] && printf '%s' "$1" | grep -Eq '^[0-9]+$'; then
  PHASE_S="$1"
fi
if [ -n "${2:-}" ] && printf '%s' "$2" | grep -Eq '^[0-9]+$'; then
  INTERVAL="$2"
fi
KEEP_WAYDROID=0
for a in "$@"; do
  case "$a" in
    --keep-waydroid) KEEP_WAYDROID=1 ;;
  esac
done
export PATH="${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

read_cap() {
  if [ -f /sys/class/power_supply/bq27411-0/capacity ]; then
    cat /sys/class/power_supply/bq27411-0/capacity
  elif [ -f /sys/class/power_supply/battery/capacity ]; then
    cat /sys/class/power_supply/battery/capacity
  else
    echo "?"
  fi
}

read_status() {
  if [ -f /sys/class/power_supply/bq27411-0/status ]; then
    cat /sys/class/power_supply/bq27411-0/status
  else
    echo "?"
  fi
}

read_online() {
  if [ -f /sys/class/power_supply/pmi8998-charger/online ]; then
    cat /sys/class/power_supply/pmi8998-charger/online
  else
    echo "?"
  fi
}

sample_phase() {
  label="$1"
  echo "## phase=$label duration_s=$PHASE_S interval_s=$INTERVAL"
  echo "t_iso,capacity,status,charger_online"
  end=$(( $(date +%s) + PHASE_S ))
  while [ "$(date +%s)" -lt "$end" ]; do
    echo "$(date -Is 2>/dev/null || date),$(read_cap),$(read_status),$(read_online)"
    sleep "$INTERVAL"
  done
}

echo "# Battery sample report"
echo "host=$(hostname 2>/dev/null || echo unknown)"
echo "started=$(date -Is 2>/dev/null || date)"
echo "note=Short window; treat as qualitative. Charging may mask drain."
echo

idle_cmd() {
  if [ "$KEEP_WAYDROID" = "1" ]; then
    phone-idle --keep-waydroid 2>/dev/null || phone-idle.sh --keep-waydroid 2>/dev/null || true
  else
    phone-idle 2>/dev/null || phone-idle.sh 2>/dev/null || true
  fi
}

# Idle posture
if command -v phone-idle >/dev/null 2>&1 || command -v phone-idle.sh >/dev/null 2>&1; then
  idle_cmd
fi
sample_phase idle

# Field posture (without logs to avoid extreme drain; still arms forwarders)
if command -v phone-field-ready >/dev/null 2>&1; then
  phone-field-ready 2>/dev/null || true
elif command -v phone-field-ready.sh >/dev/null 2>&1; then
  phone-field-ready.sh 2>/dev/null || true
fi
sample_phase field_ready

# Return to idle
if command -v phone-idle >/dev/null 2>&1 || command -v phone-idle.sh >/dev/null 2>&1; then
  idle_cmd
fi

echo
echo "ended=$(date -Is 2>/dev/null || date)"
echo "BATTERY_SAMPLE_OK"
