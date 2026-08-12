#!/bin/sh
# Short “field ready” posture: arm GPS/NFC forwarders + optional BT log session.
# Idempotent: does not reinstall units when already active.
# Call phone-idle when done (high drain if --with-logs).
#
# Soft HCI glue: prints phone-key-ready summary when that helper is installed;
# suggests waydroid-half-boot-fix when half-boot is detected.
#
# Usage:
#   phone-field-ready              # arm forwarders + auto half-boot recovery
#   phone-field-ready --with-logs  # also start bt-log-session
#   phone-field-ready --dry-run
#   phone-field-ready --fix-half-boot     # default: recover half-boot automatically
#   phone-field-ready --no-fix-half-boot  # detect only, do not restart session
set -eu

DRY=0
WITH_LOGS=0
FIX_HALF=1
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --with-logs) WITH_LOGS=1 ;;
    --fix-half-boot) FIX_HALF=1 ;;
    --no-fix-half-boot) FIX_HALF=0 ;;
    -h|--help)
      echo "Usage: phone-field-ready [--with-logs] [--fix-half-boot|--no-fix-half-boot] [--dry-run]"
      exit 0
      ;;
  esac
done

export PATH="${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

run() {
  if [ "$DRY" = "1" ]; then
    echo "DRY: $*"
  else
    "$@"
  fi
}

# Start forwarder only if not already active (avoid enable→reinstall spam).
arm_forwarder() {
  name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "$name: not installed"
    return 0
  fi
  if [ "$DRY" = "1" ]; then
    echo "DRY: arm $name if not active"
    return 0
  fi
  st=$("$name" status 2>/dev/null | head -1 || true)
  case "$st" in
    RUNNING*)
      echo "$name: already RUNNING (skip reinstall)"
      ;;
    *)
      # prefer start; enable only if unit missing/disabled
      if systemctl --user is-enabled "${name}.service" >/dev/null 2>&1 \
        || systemctl --user is-active "${name}.service" >/dev/null 2>&1; then
        "$name" start >/dev/null 2>&1 || "$name" enable >/dev/null 2>&1 || true
      else
        "$name" enable >/dev/null 2>&1 || "$name" start >/dev/null 2>&1 || true
      fi
      echo "$name: armed"
      ;;
  esac
}

print_health() {
  echo "=== health ==="
  # Prefer phone-key-ready when installed (single Soft HCI readiness surface)
  if command -v phone-key-ready >/dev/null 2>&1; then
    if [ "$DRY" = "1" ]; then
      echo "DRY: phone-key-ready (live skipped)"
    else
      phone-key-ready 2>/dev/null || true
    fi
  else
    # Soft HCI / BT host (inline fallback)
    if command -v waydroid-bt-host >/dev/null 2>&1 || [ -x /usr/bin/waydroid-bt-host ]; then
      echo "soft_hci_host: present"
    else
      echo "soft_hci_host: missing"
    fi
    if systemctl is-active waydroid-bt-host >/dev/null 2>&1; then
      echo "soft_hci_unit: active"
    else
      echo "soft_hci_unit: inactive"
    fi
    if [ -S /run/waydroid-bt/host.sock ]; then
      echo "soft_hci_sock: /run/waydroid-bt/host.sock present"
    elif [ -S /dev/socket/waydroid_bt ]; then
      echo "soft_hci_sock: /dev/socket/waydroid_bt present"
    else
      echo "soft_hci_sock: missing"
    fi
    if command -v bluetoothctl >/dev/null 2>&1; then
      powered=$(bluetoothctl show 2>/dev/null | sed -n 's/^[[:space:]]*Powered:[[:space:]]*//p' | head -1)
      echo "bluez_powered: ${powered:-unknown}"
    else
      echo "bluez_powered: bluetoothctl missing"
    fi
  fi
  # Waydroid (always show; half-boot hint)
  if command -v waydroid >/dev/null 2>&1; then
    sess=$(waydroid status 2>/dev/null | sed -n 's/^Session:[[:space:]]*//p' | tr -d '[:space:]' || true)
    ip=$(waydroid status 2>/dev/null | sed -n 's/^IP address:[[:space:]]*//p' | tr -d '[:space:]' || true)
    echo "waydroid_session: ${sess:-unknown}"
    echo "waydroid_ip: ${ip:-none}"
    boot=""
    case "$sess" in
      RUNNING*)
        if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
          if command -v timeout >/dev/null 2>&1; then
            boot=$(timeout 3 sudo -n waydroid shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n\t ' || true)
          else
            boot=$(sudo -n waydroid shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n\t ' || true)
          fi
        fi
        echo "boot_completed: ${boot:-unknown}"
        if [ "$boot" = "1" ] && [ -n "$ip" ] && [ "$ip" != "UNKNOWN" ]; then
          echo "waydroid_boot: full"
        else
          echo "waydroid_boot: half-or-booting (auto waydroid-half-boot-fix unless --no-fix-half-boot)"
          if [ "$FIX_HALF" = "1" ] && command -v waydroid-half-boot-fix >/dev/null 2>&1; then
            if [ "$DRY" = "1" ]; then
              echo "DRY: waydroid-half-boot-fix"
            else
              waydroid-half-boot-fix || true
            fi
          fi
        fi
        ;;
    esac
  else
    echo "waydroid: not installed"
  fi
  # Charge
  if [ -f /sys/class/power_supply/pmi8998-charger/online ]; then
    echo "charger_online: $(cat /sys/class/power_supply/pmi8998-charger/online 2>/dev/null)"
  fi
  if [ -f /sys/class/power_supply/bq27411-0/capacity ]; then
    echo "battery_pct: $(cat /sys/class/power_supply/bq27411-0/capacity 2>/dev/null)"
  fi
  if [ -f /sys/class/power_supply/bq27411-0/status ]; then
    echo "battery_status: $(cat /sys/class/power_supply/bq27411-0/status 2>/dev/null)"
  fi
}

echo "=== phone-field-ready ==="
arm_forwarder waydroid-gps-forward
arm_forwarder waydroid-nfc-forward

if [ "$WITH_LOGS" = "1" ]; then
  if command -v bt-log-session >/dev/null 2>&1; then
    if bt-log-session status 2>/dev/null | head -1 | grep -qiE 'running|active'; then
      echo "bt-log-session: already running"
    else
      run bt-log-session start || true
    fi
  else
    echo "bt-log-session: not installed"
  fi
else
  echo "bt-log-session: skipped (pass --with-logs near the car)"
fi

print_health
echo "FIELD_READY_OK"
echo "When done: phone-idle"
