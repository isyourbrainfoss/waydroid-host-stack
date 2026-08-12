#!/bin/sh
# Soft HCI / Phone Key readiness probe for fajita-class pmOS + Waydroid.
#
# Evaluates host Soft HCI + BlueZ + Waydroid full boot; optional guest dumpsys
# when session is fully up. Exit 0 only if critical host Soft HCI path is OK
# (and full boot when --require-guest). Exit 1 with NOT_READY and reasons.
#
# Usage:
#   phone-key-ready                 # live checks
#   phone-key-ready --require-guest # also require full Waydroid + guest BT bound
#   phone-key-ready --json          # one JSON object on stdout (plus CHECK lines on stderr)
#   phone-key-ready --selftest      # pure classification tests (no hardware)
#   phone-key-ready --dry-run       # classify using env overrides only
#
# Pure helper (testable): evaluate_phone_key_ready KEY=value...
set -eu

# --- pure evaluation --------------------------------------------------------
# Inputs via KEY=value args:
#   HOST_BIN=0|1  UNIT_ACTIVE=0|1  SOCK=0|1
#   BLUEZ_POWERED=yes|no|unknown
#   SESSION=STOPPED|RUNNING|...
#   IP=...|UNKNOWN|empty
#   BOOT=0|1|empty
#   GUEST_BT=ok|missing|unknown
#   REQUIRE_GUEST=0|1
#
# Prints lines: CHECK name=ok|fail|warn detail=...
# Final line: READY or NOT_READY reasons=...
evaluate_phone_key_ready() {
  host_bin=0 unit=0 sock=0
  bluez=unknown
  session=STOPPED ip= boot=
  guest_bt=unknown
  require_guest=0

  for kv in "$@"; do
    k=${kv%%=*}
    v=${kv#*=}
    case "$k" in
      HOST_BIN) host_bin=$v ;;
      UNIT_ACTIVE) unit=$v ;;
      SOCK) sock=$v ;;
      BLUEZ_POWERED) bluez=$v ;;
      SESSION) session=$v ;;
      IP) ip=$v ;;
      BOOT) boot=$v ;;
      GUEST_BT) guest_bt=$v ;;
      REQUIRE_GUEST) require_guest=$v ;;
    esac
  done

  reasons=""
  add_fail() {
    reasons="${reasons}${reasons:+;}$1"
  }

  if [ "$host_bin" = "1" ]; then
    echo "CHECK soft_hci_bin=ok"
  else
    echo "CHECK soft_hci_bin=fail detail=waydroid-bt-host_missing"
    add_fail "soft_hci_bin"
  fi

  if [ "$unit" = "1" ]; then
    echo "CHECK soft_hci_unit=ok"
  else
    echo "CHECK soft_hci_unit=fail detail=waydroid-bt-host_inactive"
    add_fail "soft_hci_unit"
  fi

  if [ "$sock" = "1" ]; then
    echo "CHECK soft_hci_sock=ok"
  else
    echo "CHECK soft_hci_sock=fail detail=host.sock_missing"
    add_fail "soft_hci_sock"
  fi

  case "$bluez" in
    yes|Yes|true|1)
      echo "CHECK bluez_powered=ok"
      ;;
    no|No|false|0)
      echo "CHECK bluez_powered=fail detail=adapter_off"
      add_fail "bluez_powered"
      ;;
    *)
      echo "CHECK bluez_powered=warn detail=unknown"
      ;;
  esac

  # Waydroid classification (same semantics as waydroid-half-boot-fix)
  sess_n=$(printf '%s' "$session" | tr -d '[:space:]')
  ip_n=$(printf '%s' "$ip" | tr -d '[:space:]')
  boot_n=$(printf '%s' "$boot" | tr -d '[:space:]\r')
  wb=stopped
  case "$sess_n" in
    RUNNING*)
      if [ "$boot_n" = "1" ] && [ -n "$ip_n" ] && [ "$ip_n" != "UNKNOWN" ]; then
        wb=full
      else
        wb=half
      fi
      ;;
    STOPPED*|stopped*|'')
      wb=stopped
      ;;
    *)
      wb=unknown
      ;;
  esac
  echo "CHECK waydroid_boot=$wb session=$sess_n ip=${ip_n:-none} boot=${boot_n:-none}"

  if [ "$require_guest" = "1" ]; then
    if [ "$wb" != "full" ]; then
      echo "CHECK waydroid_full=fail detail=$wb"
      add_fail "waydroid_full"
    else
      echo "CHECK waydroid_full=ok"
    fi
    case "$guest_bt" in
      ok)
        echo "CHECK guest_bt=ok"
        ;;
      missing)
        echo "CHECK guest_bt=fail detail=Bluetooth_Service_not_connected"
        add_fail "guest_bt"
        ;;
      *)
        echo "CHECK guest_bt=fail detail=unknown_or_unavailable"
        add_fail "guest_bt"
        ;;
    esac
  else
    if [ "$wb" = "full" ]; then
      echo "CHECK waydroid_full=ok (optional)"
    else
      echo "CHECK waydroid_full=skip detail=$wb (pass --require-guest to require)"
    fi
  fi

  # Critical path for Phone Key class: Soft HCI host + BlueZ
  if [ -z "$reasons" ]; then
    echo "READY"
    return 0
  fi
  echo "NOT_READY reasons=$reasons"
  return 1
}

# Emit one JSON object from evaluate stdout lines (stdin = evaluate output).
# Uses only shell + sed/tr for no jq dependency on fajita.
emit_json_from_eval() {
  ready=0
  reasons=""
  soft_hci_bin=fail soft_hci_unit=fail soft_hci_sock=fail
  bluez_powered=unknown waydroid_boot=unknown guest_bt=skip
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      READY) ready=1 ;;
      NOT_READY*)
        ready=0
        reasons=${line#NOT_READY reasons=}
        ;;
      CHECK\ soft_hci_bin=ok*) soft_hci_bin=ok ;;
      CHECK\ soft_hci_bin=fail*) soft_hci_bin=fail ;;
      CHECK\ soft_hci_unit=ok*) soft_hci_unit=ok ;;
      CHECK\ soft_hci_unit=fail*) soft_hci_unit=fail ;;
      CHECK\ soft_hci_sock=ok*) soft_hci_sock=ok ;;
      CHECK\ soft_hci_sock=fail*) soft_hci_sock=fail ;;
      CHECK\ bluez_powered=ok*) bluez_powered=ok ;;
      CHECK\ bluez_powered=fail*) bluez_powered=fail ;;
      CHECK\ bluez_powered=warn*) bluez_powered=unknown ;;
      CHECK\ waydroid_boot=*)
        waydroid_boot=$(printf '%s' "$line" | sed -n 's/^CHECK waydroid_boot=\([^ ]*\).*/\1/p')
        ;;
      CHECK\ guest_bt=ok*) guest_bt=ok ;;
      CHECK\ guest_bt=fail*) guest_bt=fail ;;
    esac
  done
  reasons_esc=$(printf '%s' "$reasons" | sed 's/"/\\"/g')
  printf '{"ready":%s,"soft_hci_bin":"%s","soft_hci_unit":"%s","soft_hci_sock":"%s","bluez_powered":"%s","waydroid_boot":"%s","guest_bt":"%s","reasons":"%s"}\n' \
    "$([ "$ready" = "1" ] && echo true || echo false)" \
    "$soft_hci_bin" "$soft_hci_unit" "$soft_hci_sock" \
    "$bluez_powered" "$waydroid_boot" "$guest_bt" "$reasons_esc"
}

# --- selftest ---------------------------------------------------------------
selftest() {
  fail=0
  echo "selftest: ready when host Soft HCI + BlueZ ok, guest optional"
  out=$(evaluate_phone_key_ready HOST_BIN=1 UNIT_ACTIVE=1 SOCK=1 BLUEZ_POWERED=yes \
    SESSION=STOPPED IP= BOOT= REQUIRE_GUEST=0) || true
  echo "$out" | grep -q '^READY$' || { echo "FAIL expected READY"; fail=1; echo "$out"; }
  echo "ok ready host-only"

  echo "selftest: not ready missing sock"
  if evaluate_phone_key_ready HOST_BIN=1 UNIT_ACTIVE=1 SOCK=0 BLUEZ_POWERED=yes \
    SESSION=STOPPED REQUIRE_GUEST=0 >/tmp/pkr-st.out 2>&1; then
    echo "FAIL expected non-zero"; fail=1
  else
    grep -q 'NOT_READY reasons=.*soft_hci_sock' /tmp/pkr-st.out \
      || { echo "FAIL reasons"; cat /tmp/pkr-st.out; fail=1; }
    echo "ok fail closed on sock"
  fi

  echo "selftest: bluez off fails closed"
  if evaluate_phone_key_ready HOST_BIN=1 UNIT_ACTIVE=1 SOCK=1 BLUEZ_POWERED=no \
    SESSION=STOPPED REQUIRE_GUEST=0 >/tmp/pkr-st-bz.out 2>&1; then
    echo "FAIL expected NOT_READY for bluez off"; fail=1
  else
    grep -q 'bluez_powered' /tmp/pkr-st-bz.out || { echo "FAIL no bluez reason"; fail=1; }
    echo "ok fail closed on bluez"
  fi

  echo "selftest: require guest half-boot fails"
  if evaluate_phone_key_ready HOST_BIN=1 UNIT_ACTIVE=1 SOCK=1 BLUEZ_POWERED=yes \
    SESSION=RUNNING IP=UNKNOWN BOOT=0 GUEST_BT=unknown REQUIRE_GUEST=1 \
    >/tmp/pkr-st2.out 2>&1; then
    echo "FAIL expected NOT_READY"; fail=1
  else
    grep -q 'waydroid_full' /tmp/pkr-st2.out || { echo "FAIL no waydroid_full"; fail=1; }
    echo "ok require-guest half-boot"
  fi

  echo "selftest: require guest full + guest_bt ok"
  if ! evaluate_phone_key_ready HOST_BIN=1 UNIT_ACTIVE=1 SOCK=1 BLUEZ_POWERED=yes \
    SESSION=RUNNING IP=192.168.240.112 BOOT=1 GUEST_BT=ok REQUIRE_GUEST=1 \
    >/tmp/pkr-st3.out 2>&1; then
    echo "FAIL expected READY"; cat /tmp/pkr-st3.out; fail=1
  else
    grep -q '^READY$' /tmp/pkr-st3.out || fail=1
    echo "ok require-guest full"
  fi

  echo "selftest: require guest full + guest_bt missing fails"
  if evaluate_phone_key_ready HOST_BIN=1 UNIT_ACTIVE=1 SOCK=1 BLUEZ_POWERED=yes \
    SESSION=RUNNING IP=192.168.240.112 BOOT=1 GUEST_BT=missing REQUIRE_GUEST=1 \
    >/tmp/pkr-st4.out 2>&1; then
    echo "FAIL expected NOT_READY guest_bt"; fail=1
  else
    grep -q 'guest_bt' /tmp/pkr-st4.out || { echo "FAIL no guest_bt"; fail=1; }
    echo "ok require-guest guest_bt missing"
  fi

  echo "selftest: json emission"
  j=$(evaluate_phone_key_ready HOST_BIN=1 UNIT_ACTIVE=1 SOCK=1 BLUEZ_POWERED=yes \
    SESSION=STOPPED REQUIRE_GUEST=0 | emit_json_from_eval)
  echo "$j" | grep -q '"ready":true' || { echo "FAIL json ready true: $j"; fail=1; }
  j2=$(evaluate_phone_key_ready HOST_BIN=0 UNIT_ACTIVE=0 SOCK=0 BLUEZ_POWERED=no \
    SESSION=STOPPED REQUIRE_GUEST=0 | emit_json_from_eval || true)
  echo "$j2" | grep -q '"ready":false' || { echo "FAIL json ready false: $j2"; fail=1; }
  echo "ok json"

  rm -f /tmp/pkr-st.out /tmp/pkr-st2.out /tmp/pkr-st3.out /tmp/pkr-st4.out /tmp/pkr-st-bz.out
  if [ "$fail" -ne 0 ]; then
    echo "PHONE_KEY_READY_SELFTEST_FAILED"
    return 1
  fi
  echo "ALL_PHONE_KEY_READY_SELFTESTS_OK"
  return 0
}

# If sourced for pure tests:
if [ "${PHONE_KEY_READY_PURE:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# --- live collection --------------------------------------------------------
REQUIRE_GUEST=0
JSON=0
DRY=0
for a in "$@"; do
  case "$a" in
    --selftest) selftest; exit $? ;;
    --require-guest) REQUIRE_GUEST=1 ;;
    --json) JSON=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help)
      echo "Usage: phone-key-ready [--require-guest] [--json] [--selftest] [--dry-run]"
      exit 0
      ;;
  esac
done

export PATH="${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

run_eval() {
  # shellcheck disable=SC2086
  evaluate_phone_key_ready "$@"
}

collect_and_eval() {
  host_bin=0
  if command -v waydroid-bt-host >/dev/null 2>&1 || [ -x /usr/bin/waydroid-bt-host ]; then
    host_bin=1
  fi
  unit=0
  if systemctl is-active waydroid-bt-host >/dev/null 2>&1 \
    || systemctl --user is-active waydroid-bt-host >/dev/null 2>&1; then
    unit=1
  fi
  sock=0
  if [ -S /run/waydroid-bt/host.sock ] || [ -S /dev/socket/waydroid_bt ]; then
    sock=1
  fi
  bluez=unknown
  if command -v bluetoothctl >/dev/null 2>&1; then
    p=$(bluetoothctl show 2>/dev/null | sed -n 's/^[[:space:]]*Powered:[[:space:]]*//p' | head -1 | tr '[:upper:]' '[:lower:]')
    case "$p" in
      yes) bluez=yes ;;
      no) bluez=no ;;
    esac
  fi
  session=STOPPED
  ip=
  boot=
  guest_bt=unknown
  if command -v waydroid >/dev/null 2>&1; then
    session=$(waydroid status 2>/dev/null | sed -n 's/^Session:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
    ip=$(waydroid status 2>/dev/null | sed -n 's/^IP address:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      if command -v timeout >/dev/null 2>&1; then
        boot=$(timeout 3 sudo -n waydroid shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n\t ' || true)
      else
        boot=$(sudo -n waydroid shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n\t ' || true)
      fi
      if [ "$boot" = "1" ] && [ -n "$ip" ] && [ "$ip" != "UNKNOWN" ]; then
        if command -v timeout >/dev/null 2>&1; then
          dump=$(timeout 8 sudo -n waydroid shell dumpsys bluetooth_manager 2>/dev/null || true)
        else
          dump=$(sudo -n waydroid shell dumpsys bluetooth_manager 2>/dev/null || true)
        fi
        if echo "$dump" | grep -q 'Bluetooth Service not connected'; then
          guest_bt=missing
        elif echo "$dump" | grep -qiE 'AdapterProperties|enabled: true|state:.*ON'; then
          guest_bt=ok
        elif [ -n "$dump" ]; then
          guest_bt=ok
        fi
      fi
    fi
  fi

  if [ "$JSON" != "1" ]; then
    echo "=== phone-key-ready (live) ==="
    echo "  HOST_BIN=$host_bin UNIT_ACTIVE=$unit SOCK=$sock BLUEZ_POWERED=$bluez"
    echo "  SESSION=${session:-STOPPED} IP=${ip} BOOT=${boot} GUEST_BT=$guest_bt REQUIRE_GUEST=$REQUIRE_GUEST"
  fi

  # Capture evaluate output for optional JSON
  eval_out=$(run_eval \
    "HOST_BIN=$host_bin" "UNIT_ACTIVE=$unit" "SOCK=$sock" "BLUEZ_POWERED=$bluez" \
    "SESSION=${session:-STOPPED}" "IP=${ip}" "BOOT=${boot}" "GUEST_BT=$guest_bt" \
    "REQUIRE_GUEST=$REQUIRE_GUEST") || true

  if [ "$JSON" = "1" ]; then
    printf '%s\n' "$eval_out" | emit_json_from_eval
  else
    printf '%s\n' "$eval_out"
  fi

  echo "$eval_out" | grep -q '^READY$'
}

if [ "$DRY" = "1" ]; then
  eval_out=$(run_eval \
    "HOST_BIN=${HOST_BIN:-1}" "UNIT_ACTIVE=${UNIT_ACTIVE:-1}" "SOCK=${SOCK:-1}" \
    "BLUEZ_POWERED=${BLUEZ_POWERED:-yes}" "SESSION=${SESSION:-STOPPED}" \
    "IP=${IP:-}" "BOOT=${BOOT:-}" "GUEST_BT=${GUEST_BT:-unknown}" \
    "REQUIRE_GUEST=$REQUIRE_GUEST") || true
  if [ "$JSON" = "1" ]; then
    printf '%s\n' "$eval_out" | emit_json_from_eval
  else
    printf '%s\n' "$eval_out"
  fi
  echo "$eval_out" | grep -q '^READY$'
  exit $?
fi

if collect_and_eval; then
  if [ "$JSON" != "1" ]; then
    echo "PHONE_KEY_READY_OK"
  fi
  exit 0
fi
if [ "$JSON" != "1" ]; then
  echo "PHONE_KEY_NOT_READY"
  echo "Hints: systemctl status waydroid-bt-host; ls /run/waydroid-bt/host.sock;"
  echo "  bluetoothctl power on; waydroid-half-boot-fix; phone-key-ready --require-guest"
fi
exit 1
