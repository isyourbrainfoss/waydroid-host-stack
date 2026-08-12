#!/bin/sh
# Umbrella install: GPS forward + NFC forward + bt-log-session helpers.
# Soft HCI host is check-only (not rebuilt here).
#
# Usage:
#   sh scripts/install-waydroid-stack.sh
#   sh scripts/install-waydroid-stack.sh --with-nfc-host-stack
#   sh scripts/install-waydroid-stack.sh --dry-run
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
DRY=0
NFC_HOST=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --with-nfc-host-stack) NFC_HOST=1 ;;
    -h|--help)
      echo "Usage: $0 [--with-nfc-host-stack] [--dry-run]"
      exit 0
      ;;
  esac
done

run() {
  if [ "$DRY" = "1" ]; then
    echo "DRY: $*"
  else
    "$@"
  fi
}

echo "=== install-waydroid-stack (from $ROOT) ==="

if [ ! -f "$ROOT/scripts/install-waydroid-gps-forward.sh" ]; then
  echo "Missing GPS install script under $ROOT/scripts" >&2
  exit 1
fi

echo "--- GPS forward ---"
run sh "$ROOT/scripts/install-waydroid-gps-forward.sh"

echo "--- NFC forward ---"
if [ "$NFC_HOST" = "1" ]; then
  run sh "$ROOT/scripts/install-waydroid-nfc-forward.sh" --with-host-stack
else
  run sh "$ROOT/scripts/install-waydroid-nfc-forward.sh"
fi

echo "--- BT log session ---"
run sh "$ROOT/scripts/install-bt-log-session.sh"

# Profile helpers + pull + Soft HCI readiness
mkdir -p "${HOME}/.local/bin"
for s in phone-field-ready.sh phone-idle.sh pull-field-session.sh \
  waydroid-half-boot-fix.sh phone-battery-sample.sh nfc-host-diag.sh \
  phone-key-ready.sh waydroid-force-normal-boot.sh; do
  if [ -f "$ROOT/scripts/$s" ]; then
    dest="${HOME}/.local/bin/$(echo "$s" | sed 's/\.sh$//')"
    case "$s" in
      pull-field-session.sh)
        run install -m 0755 "$ROOT/scripts/$s" "${HOME}/.local/bin/pull-field-session"
        run install -m 0755 "$ROOT/scripts/$s" "${HOME}/.local/bin/pull-field-session.sh"
        ;;
      *)
        run install -m 0755 "$ROOT/scripts/$s" "$dest"
        ;;
    esac
  fi
done

echo "--- Force normal boot overlay (charger cmdline fix) ---"
if [ -f "$ROOT/scripts/waydroid-force-normal-boot.sh" ]; then
  run sh "$ROOT/scripts/waydroid-force-normal-boot.sh" install || true
else
  echo "waydroid-force-normal-boot: script missing"
fi

echo "--- Soft HCI host (check only) ---"
if command -v waydroid-bt-host >/dev/null 2>&1; then
  echo "waydroid-bt-host: present ($(command -v waydroid-bt-host))"
elif [ -x /usr/bin/waydroid-bt-host ] || [ -x /usr/local/bin/waydroid-bt-host ]; then
  echo "waydroid-bt-host: binary on system path"
else
  echo "waydroid-bt-host: not found — Soft HCI host not installed by this umbrella"
  echo "  See docs/pmOS-setup.md / cargo build -p waydroid-bt-host"
fi
if systemctl is-active waydroid-bt-host >/dev/null 2>&1; then
  echo "waydroid-bt-host.service: active"
elif systemctl --user is-active waydroid-bt-host >/dev/null 2>&1; then
  echo "waydroid-bt-host user unit: active"
else
  echo "waydroid-bt-host.service: not active (ok if not deployed yet)"
fi

echo "UMBRELLA_INSTALL_OK"
