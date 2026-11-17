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

echo "=== desk-check: soft HCI unit tests (host g++) ==="
if command -v g++ >/dev/null 2>&1; then
  if ! g++ -std=c++17 -O1 -I"$ROOT/guest/hal" "$ROOT/guest/hal/soft_hci_test.cpp" \
    "$ROOT/guest/hal/soft_hci.cpp" "$ROOT/guest/hal/soft_hci_att.cpp" \
    "$ROOT/guest/hal/bridge_ipc.cpp" -o /tmp/whs-soft-hci-test -lpthread ||
    ! /tmp/whs-soft-hci-test; then
    fail=1
  fi
elif [ -n "${ANDROID_NDK_HOME:-}" ] && [ -x "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/clang++" ]; then
  # No host g++: NDK clang, static x86_64 Android binary (runs on the Linux host).
  if ! "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/clang++" \
    --target=x86_64-linux-android33 -static -std=c++17 -O1 -I"$ROOT/guest/hal" \
    "$ROOT/guest/hal/soft_hci_test.cpp" "$ROOT/guest/hal/soft_hci.cpp" \
    "$ROOT/guest/hal/soft_hci_att.cpp" "$ROOT/guest/hal/bridge_ipc.cpp" \
    -o /tmp/whs-soft-hci-test || ! /tmp/whs-soft-hci-test; then
    fail=1
  fi
else
  echo "skip: g++ not installed (set ANDROID_NDK_HOME to use NDK clang)"
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
