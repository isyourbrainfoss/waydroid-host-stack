#!/bin/sh
# Offline golden: pull-field-session --local on Phone Key fixture must surface
# whitelist → unlocked timeline (desk proof of field evidence loop).
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures/phone-key-golden"
SCRIPT="$ROOT/scripts/pull-field-session.sh"
fail=0

if [ ! -d "$FIX/bt-session" ]; then
  echo "FAIL missing golden fixture $FIX"
  exit 1
fi

# Work on a copy so SUMMARY/SIZES writes do not dirty the fixture permanently
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cp -a "$FIX/." "$tmpdir/"

echo "selftest: golden pull --local"
OUT=$(sh "$SCRIPT" --local "$tmpdir" 2>&1) || true
echo "$OUT" | grep -q PULL_LOCAL_OK || { echo "FAIL PULL_LOCAL_OK"; echo "$OUT"; fail=1; }
test -f "$tmpdir/SUMMARY.md" || { echo "FAIL SUMMARY.md"; fail=1; }

echo "selftest: timeline section present"
grep -q 'Tesla Phone Key timeline' "$tmpdir/SUMMARY.md" \
  || { echo "FAIL timeline section"; fail=1; }

echo "selftest: Did NOT find key → whitelist → unlocked"
grep -q 'Did NOT find key' "$tmpdir/SUMMARY.md" \
  || { echo "FAIL missing Did NOT find key"; fail=1; }
grep -qE 'Found \[.*\] in whitelist' "$tmpdir/SUMMARY.md" \
  || { echo "FAIL missing Found in whitelist"; fail=1; }
grep -qiE 'unlocked' "$tmpdir/SUMMARY.md" \
  || { echo "FAIL missing unlocked"; fail=1; }

echo "selftest: soft-hci artifact checklist"
grep -q 'soft-hci/waydroid-bt-host.journal.txt' "$tmpdir/SUMMARY.md" \
  || { echo "FAIL soft-hci checklist"; fail=1; }

if [ "$fail" -ne 0 ]; then
  echo "PHONE_KEY_GOLDEN_SELFTEST_FAILED"
  echo "--- SUMMARY.md (head) ---"
  head -60 "$tmpdir/SUMMARY.md" 2>/dev/null || true
  exit 1
fi
echo "ALL_PHONE_KEY_GOLDEN_SELFTESTS_OK"
