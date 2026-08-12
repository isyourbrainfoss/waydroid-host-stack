#!/bin/sh
# Structural + offline tests for pull-field-session (no live SSH required).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/pull-field-session.sh"
fail=0

echo "selftest: REMOTE_HOME present"
grep -q 'REMOTE_HOME=' "$SCRIPT" || { echo "FAIL no REMOTE_HOME"; fail=1; }

echo "selftest: no desk \$HOME in scp remote path"
if grep -nE 'scp .*\$HOST:\$HOME' "$SCRIPT"; then
  echo "FAIL scp uses desk-expanded \$HOME"
  fail=1
else
  echo "ok no HOST:\$HOME scp"
fi

echo "selftest: skip-logcat default flag parsing"
grep -q 'SKIP_LOGCAT' "$SCRIPT" || { echo "FAIL no SKIP_LOGCAT"; fail=1; }

echo "selftest: --local summary"
tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/bt-session" "$tmpdir/gps"
printf '%s\n' 'Found [abc] in whitelist!' 'BLEVehicleController unlocked' >"$tmpdir/bt-session/sample.log"
OUT=$(sh "$SCRIPT" --local "$tmpdir" 2>&1) || true
echo "$OUT" | grep -q PULL_LOCAL_OK || { echo "FAIL PULL_LOCAL_OK"; fail=1; }
test -f "$tmpdir/SUMMARY.md" || { echo "FAIL SUMMARY.md"; fail=1; }
grep -q whitelist "$tmpdir/SUMMARY.md" || { echo "FAIL summary greps"; fail=1; }
grep -q 'Tesla Phone Key timeline' "$tmpdir/SUMMARY.md" || { echo "FAIL timeline section"; fail=1; }
echo "ok local summary"
rm -rf "$tmpdir"

if [ "$fail" -ne 0 ]; then
  echo "PULL_SELFTEST_FAILED"
  exit 1
fi
echo "ALL_PULL_SELFTESTS_OK"
