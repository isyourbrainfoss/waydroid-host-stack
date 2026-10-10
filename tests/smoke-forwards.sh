#!/bin/sh
# Host-side smoke: pure selftests for GPS + NFC forwarders (no phone required).
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
fail=0
echo "=== gps-forward selftest ==="
if ! sh "$ROOT/tests/gps-forward-selftest.sh"; then
  fail=1
fi
echo "=== nfc-forward selftest ==="
if ! sh "$ROOT/tests/nfc-forward-selftest.sh"; then
  fail=1
fi
echo "=== pull-field-session selftest ==="
if ! sh "$ROOT/tests/pull-field-session-selftest.sh"; then
  fail=1
fi
echo "=== half-boot parse selftest ==="
if ! sh "$ROOT/scripts/waydroid-half-boot-fix.sh" --selftest; then
  fail=1
fi
echo "=== phone-key-ready selftest ==="
if ! sh "$ROOT/scripts/phone-key-ready.sh" --selftest; then
  fail=1
fi
echo "=== force-normal-boot selftest ==="
if ! sh "$ROOT/scripts/waydroid-force-normal-boot.sh" --selftest; then
  fail=1
fi
echo "=== golden Phone Key fixture (pull --local) ==="
if ! sh "$ROOT/tests/phone-key-golden-selftest.sh"; then
  fail=1
fi
# Structural presence
for f in \
  "$ROOT/scripts/waydroid-gps-forward.sh" \
  "$ROOT/scripts/waydroid-nfc-forward.sh" \
  "$ROOT/scripts/install-waydroid-gps-forward.sh" \
  "$ROOT/scripts/install-waydroid-nfc-forward.sh" \
  "$ROOT/scripts/install-waydroid-stack.sh" \
  "$ROOT/scripts/pull-field-session.sh" \
  "$ROOT/scripts/phone-field-ready.sh" \
  "$ROOT/scripts/phone-idle.sh" \
  "$ROOT/scripts/waydroid-half-boot-fix.sh" \
  "$ROOT/scripts/phone-key-ready.sh" \
  "$ROOT/scripts/waydroid-force-normal-boot.sh" \
  "$ROOT/scripts/phone-battery-sample.sh" \
  "$ROOT/scripts/nfc-host-diag.sh" \
  "$ROOT/scripts/desk-check.sh" \
  "$ROOT/tests/fixtures/phone-key-golden/bt-session/guest-logcat-tesla-sample.log" \
  "$ROOT/docs/tesla-day-of.md" \
  "$ROOT/Makefile" \
  "$ROOT/docs/gps-forward.md" \
  "$ROOT/docs/nfc-forward.md" \
  "$ROOT/docs/phone-ready.md" \
  "$ROOT/docs/field-logs.md" \
  "$ROOT/docs/pmOS-setup.md"
do
  if [ ! -f "$f" ]; then
    echo "MISSING $f"
    fail=1
  fi
done
# Hygiene helper must exist in shipped GPS script
if ! grep -q 'should_update_last_known' "$ROOT/scripts/waydroid-gps-forward.sh"; then
  echo "MISSING should_update_last_known in gps forwarder"
  fail=1
fi
# City-level live must not beat stale last-known (selftest case in shipped script)
if ! grep -q 'prefers stale last-known over city-level live' "$ROOT/scripts/waydroid-gps-forward.sh"; then
  echo "MISSING stale+city-level pick_fix selftest in gps forwarder"
  fail=1
fi
# pull-field-session must resolve remote HOME (not desk $HOME) for scp
if ! grep -q 'REMOTE_HOME=' "$ROOT/scripts/pull-field-session.sh"; then
  echo "MISSING REMOTE_HOME resolution in pull-field-session"
  fail=1
fi
if grep -nE 'scp .*\$HOST:\$HOME' "$ROOT/scripts/pull-field-session.sh"; then
  echo "FAIL pull-field-session still scp's with desk-expanded \$HOME"
  fail=1
fi
# Umbrella must ship phone-key-ready
if ! grep -q 'phone-key-ready' "$ROOT/scripts/install-waydroid-stack.sh"; then
  echo "MISSING phone-key-ready in install-waydroid-stack"
  fail=1
fi
# Docs: Soft HCI is shipped field LE; Strategy A is cleanup (not current stack)
if ! grep -q 'Shipped field path' "$ROOT/docs/architecture.md"; then
  echo "MISSING shipped Soft HCI field-path wording in architecture.md"
  fail=1
fi
if ! grep -q 'cleanup north star' "$ROOT/docs/architecture.md"; then
  echo "MISSING Strategy A cleanup north star wording in architecture.md"
  fail=1
fi
if ! grep -q 'Shipped field path' "$ROOT/guest/README.md"; then
  echo "MISSING shipped Soft HCI field-path wording in guest/README.md"
  fail=1
fi
# half-boot hard path present
if ! grep -q 'container stop' "$ROOT/scripts/waydroid-half-boot-fix.sh"; then
  echo "MISSING hard container recovery in half-boot-fix"
  fail=1
fi
if [ "$fail" -ne 0 ]; then
  echo "SMOKE_FORWARDS_FAILED"
  exit 1
fi
echo "ALL_SMOKE_FORWARDS_OK"
