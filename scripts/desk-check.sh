#!/bin/sh
# One desk gate: forwarder smoke selftests + cargo test --workspace.
# Exit non-zero if any component fails.
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0
echo "=== desk-check: smoke-forwards ==="
if ! sh "$ROOT/tests/smoke-forwards.sh"; then
  fail=1
fi

echo "=== desk-check: cargo test --workspace ==="
if ! cargo test --workspace; then
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "DESK_CHECK_FAILED"
  exit 1
fi
echo "DESK_CHECK_OK"
