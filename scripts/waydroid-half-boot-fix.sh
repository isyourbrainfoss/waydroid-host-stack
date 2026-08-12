#!/bin/sh
# Detect Waydroid half-boot and optionally restart the session to full boot.
#
# Half-boot: Session RUNNING but IP UNKNOWN and/or sys.boot_completed ≠ 1.
# Healthy full boot: leave alone (exit 0, report full).
#
# Recovery path (hardened):
#   1) soft: session stop → start (timed)
#   2) hard: container stop → systemctl start waydroid-container + session start
#   3) coldboot marker poke (ueventd hang workaround, same as waydroid-start-ui)
# getprop always hard-capped so a hung shell cannot wedge this script.
#
# Usage:
#   waydroid-half-boot-fix              # detect + restart if half
#   waydroid-half-boot-fix --check-only # detect only
#   waydroid-half-boot-fix --force      # stop/start even if looks full
#   waydroid-half-boot-fix --dry-run
#   waydroid-half-boot-fix --selftest
#
# Pure helper (testable): parse_waydroid_half_boot <session> <ip> <boot>
#   prints: full | half | stopped | unknown
set -eu

# --- pure status classification (shipped entry for unit tests) --------------
parse_waydroid_half_boot() {
  sess=$(printf '%s' "${1:-}" | tr -d '[:space:]')
  ip=$(printf '%s' "${2:-}" | tr -d '[:space:]')
  boot=$(printf '%s' "${3:-}" | tr -d '[:space:]\r')
  case "$sess" in
    ''|STOPPED*|stopped*)
      echo stopped
      return 0
      ;;
    RUNNING*)
      if [ "$boot" = "1" ] && [ -n "$ip" ] && [ "$ip" != "UNKNOWN" ]; then
        echo full
      else
        echo half
      fi
      return 0
      ;;
    *)
      echo unknown
      return 0
      ;;
  esac
}

# If sourced for pure tests:
if [ "${WAYDROID_HALF_BOOT_PURE:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

CHECK_ONLY=0
FORCE=0
DRY=0
# Max poll iterations after each restart attempt (~2s each)
WAIT_ITERS="${HALF_BOOT_WAIT_ITERS:-45}"
for a in "$@"; do
  case "$a" in
    --check-only) CHECK_ONLY=1 ;;
    --force) FORCE=1 ;;
    --dry-run) DRY=1 ;;
    --selftest)
      fail=0
      o=$(parse_waydroid_half_boot "RUNNING" "192.168.240.1" "1")
      [ "$o" = "full" ] || { echo "FAIL full got $o"; fail=1; }
      o=$(parse_waydroid_half_boot "RUNNING" "UNKNOWN" "0")
      [ "$o" = "half" ] || { echo "FAIL half ip got $o"; fail=1; }
      o=$(parse_waydroid_half_boot "RUNNING" "192.168.240.1" "0")
      [ "$o" = "half" ] || { echo "FAIL half boot got $o"; fail=1; }
      o=$(parse_waydroid_half_boot "RUNNING" "UNKNOWN" "1")
      [ "$o" = "half" ] || { echo "FAIL half ip+boot1 got $o"; fail=1; }
      o=$(parse_waydroid_half_boot "STOPPED" "" "")
      [ "$o" = "stopped" ] || { echo "FAIL stopped got $o"; fail=1; }
      o=$(parse_waydroid_half_boot "STARTING" "" "")
      [ "$o" = "unknown" ] || { echo "FAIL unknown got $o"; fail=1; }
      # Ensure script has timeout + hard path markers (structural, desk-safe)
      me=$(readlink -f "$0" 2>/dev/null || echo "$0")
      grep -q 'timeout' "$me" || { echo "FAIL missing timeout usage"; fail=1; }
      grep -q 'container stop' "$me" || { echo "FAIL missing hard container path"; fail=1; }
      grep -q 'coldboot_done' "$me" || { echo "FAIL missing coldboot poke"; fail=1; }
      grep -q 'start_session_bg' "$me" || { echo "FAIL missing bg session start"; fail=1; }
      # Must never wrap session start in timeout (kills long-lived session)
      if grep -nE 'timeout[[:space:]]+[0-9]+[[:space:]]+waydroid session start' "$me"; then
        echo "FAIL session start must not use timeout"; fail=1
      fi
      if [ "$fail" -eq 0 ]; then
        echo "ALL_HALF_BOOT_PARSE_OK"
        exit 0
      fi
      echo "HALF_BOOT_PARSE_FAILED"
      exit 1
      ;;
    -h|--help)
      echo "Usage: waydroid-half-boot-fix [--check-only|--force|--dry-run|--selftest]"
      exit 0
      ;;
  esac
done

export PATH="${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

if ! command -v waydroid >/dev/null 2>&1; then
  echo "waydroid: not installed"
  exit 1
fi

# Run a command with optional timeout; never hang the recovery path.
run_to() {
  secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@" 2>/dev/null || true
  else
    "$@" 2>/dev/null || true
  fi
}

read_status() {
  sess=$(run_to 5 waydroid status | sed -n 's/^Session:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
  ip=$(run_to 5 waydroid status | sed -n 's/^IP address:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
  boot=""
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    # getprop can hang on half-boot — hard cap wait
    boot=$(run_to 3 sudo -n waydroid shell getprop sys.boot_completed | tr -d '\r\n\t ' || true)
  fi
  echo "$sess|$ip|$boot"
}

wait_for_full() {
  label="$1"
  ok=0
  i=0
  while [ "$i" -lt "$WAIT_ITERS" ]; do
    line=$(read_status)
    sess=$(printf '%s' "$line" | cut -d'|' -f1)
    ip=$(printf '%s' "$line" | cut -d'|' -f2)
    boot=$(printf '%s' "$line" | cut -d'|' -f3)
    state=$(parse_waydroid_half_boot "$sess" "$ip" "$boot")
    echo "wait[$label] i=$i session=$sess ip=$ip boot=$boot state=$state"
    if [ "$state" = "full" ]; then
      ok=1
      break
    fi
    i=$((i + 1))
    sleep 2
  done
  [ "$ok" = "1" ]
}

# waydroid session start is long-lived (holds the session open). NEVER wrap it
# in `timeout` — that kills the session after N seconds and leaves STOPPED.
# Start detached; wait_for_full polls readiness separately.
start_session_bg() {
  log=${HALF_BOOT_SESSION_LOG:-/tmp/waydroid-half-boot-session.log}
  # Drop any stale start that is still hanging around (best-effort)
  # shellcheck disable=SC2009
  pids=$(ps -ef 2>/dev/null | awk '/waydroid session start/ && !/awk/ {print $2}' || true)
  for p in $pids; do
    kill "$p" 2>/dev/null || true
  done
  # nohup + background so this script can poll without blocking forever
  nohup waydroid session start >"$log" 2>&1 &
  echo "recovery: session start pid=$! log=$log"
  sleep 2
}

# Soft: session restart only
soft_restart() {
  echo "recovery: soft session stop/start"
  run_to 20 waydroid session stop || true
  sleep 2
  start_session_bg
}

# Hard: container bounce (zombie half-boot / stuck lxc)
hard_restart() {
  echo "recovery: hard container + session restart"
  run_to 20 waydroid session stop || true
  sleep 1
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    run_to 30 sudo -n waydroid container stop || true
    sleep 1
    run_to 30 sudo -n systemctl start waydroid-container || true
    sleep 1
  else
    echo "recovery: no passwordless sudo — skipping container bounce"
  fi
  start_session_bg
}

# Coldboot marker poke (ueventd hang workaround from waydroid-start-ui)
poke_coldboot() {
  if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
    return 0
  fi
  echo "recovery: coldboot marker poke (background, 15s)"
  (
    j=0
    while [ "$j" -lt 15 ]; do
      pid=$(sudo -n lxc-info -P /var/lib/waydroid/lxc -n waydroid -pH 2>/dev/null || true)
      if [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; then
        if [ -e "/proc/$pid/root/dev/.booting" ] || [ ! -e "/proc/$pid/root/dev/.coldboot_done" ]; then
          sudo -n rm -f "/proc/$pid/root/dev/.booting" 2>/dev/null || true
          sudo -n sh -c "echo -n > /proc/$pid/root/dev/.coldboot_done" 2>/dev/null || true
        fi
      fi
      j=$((j + 1))
      sleep 1
    done
  ) &
}

ensure_xdg_bind() {
  if [ ! -e /run/xdg/wayland-0 ] && [ -S "${XDG_RUNTIME_DIR}/wayland-0" ]; then
    sudo -n mkdir -p /run/xdg 2>/dev/null || true
    sudo -n mount --bind "$XDG_RUNTIME_DIR" /run/xdg 2>/dev/null || true
  fi
}

# OnePlus/pmOS: host cmdline may include androidboot.mode=charger → guest stuck
# without zygote. Ensure overlay init.rc is installed before restart attempts.
ensure_force_normal_boot() {
  if command -v waydroid-force-normal-boot >/dev/null 2>&1; then
    waydroid-force-normal-boot install 2>/dev/null || true
    return 0
  fi
  # Inline minimal install if helper not on PATH yet
  ov=/var/lib/waydroid/overlay/system/etc/init
  rc="$ov/waydroid_force_normal_boot.rc"
  if [ -f "$rc" ]; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo -n mkdir -p "$ov" 2>/dev/null || true
    # shellcheck disable=SC2016
    sudo -n tee "$rc" >/dev/null 2>/dev/null <<'RC' || true
on charger
    class_start main
    class_start late_start
    trigger late-init
    trigger boot
    trigger nonencrypted
    trigger post-fs-data
    trigger zygote-start
RC
    echo "recovery: installed force-normal-boot overlay (charger→main)"
  fi
}

line=$(read_status)
sess=$(printf '%s' "$line" | cut -d'|' -f1)
ip=$(printf '%s' "$line" | cut -d'|' -f2)
boot=$(printf '%s' "$line" | cut -d'|' -f3)
state=$(parse_waydroid_half_boot "$sess" "$ip" "$boot")

echo "session=$sess ip=$ip boot_completed=$boot state=$state"

if [ "$CHECK_ONLY" = "1" ]; then
  echo "HALF_BOOT_CHECK=$state"
  exit 0
fi

if [ "$state" = "full" ] && [ "$FORCE" != "1" ]; then
  echo "Waydroid already full boot — no restart"
  echo "HALF_BOOT_OK full"
  exit 0
fi

if [ "$state" = "stopped" ] && [ "$FORCE" != "1" ]; then
  echo "Session stopped — will start session"
fi

if [ "$DRY" = "1" ]; then
  echo "DRY: would soft then hard restart for state=$state"
  echo "HALF_BOOT_DRY"
  exit 0
fi

ensure_xdg_bind
ensure_force_normal_boot

# Attempt 1: soft session restart
soft_restart
poke_coldboot
if wait_for_full soft; then
  echo "HALF_BOOT_OK full (soft)"
  exit 0
fi

# Attempt 2: hard container bounce
echo "recovery: soft path did not reach full boot — escalating"
hard_restart
poke_coldboot
if wait_for_full hard; then
  echo "HALF_BOOT_OK full (hard)"
  exit 0
fi

line=$(read_status)
sess=$(printf '%s' "$line" | cut -d'|' -f1)
ip=$(printf '%s' "$line" | cut -d'|' -f2)
boot=$(printf '%s' "$line" | cut -d'|' -f3)
state=$(parse_waydroid_half_boot "$sess" "$ip" "$boot")
echo "HALF_BOOT_BLOCKED state=$state (session may still be booting or hung)"
echo "Hints: waydroid status; sudo waydroid container restart; journalctl -u waydroid-container"
exit 1
