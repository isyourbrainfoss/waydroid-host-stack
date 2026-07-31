#!/usr/bin/env bash
# Cross-build soft Bluetooth HCI HAL for aarch64 Android (API 33).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HAL="$ROOT/guest/hal"
SCRATCH="${HAL_BUILD_DIR:-/tmp/waydroid-bt-hal-build}"
NDK="${ANDROID_NDK_HOME:-$HOME/Android/Sdk/ndk/28.2.13676358}"
API=33
TRIPLE=aarch64-linux-android
CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/${TRIPLE}${API}-clang++"

# Paths prepared by the goal implementer (headers + guest libs)
INC_GEN="${HAL_INC_GEN:?set HAL_INC_GEN to hidl-gen output}"
INC_LIBHIDL="${HAL_INC_LIBHIDL:?}"
INC_LIBLOG="${HAL_INC_LIBLOG:?}"
INC_LIBBASE="${HAL_INC_LIBBASE:?}"
INC_LIBUTILS="${HAL_INC_LIBUTILS:?}"
INC_LIBCUTILS="${HAL_INC_LIBCUTILS:?}"
SYSROOT_LIB="${HAL_SYSROOT_LIB:?}"

mkdir -p "$SCRATCH"
OUT="$SCRATCH/android.hardware.bluetooth@1.0-service.waydroid"

"$CC" -std=c++17 -O2 -fPIC \
  -I"$HAL" \
  -I"$INC_GEN" \
  -I"$INC_LIBHIDL/base/include" \
  -I"$INC_LIBHIDL/transport/include" \
  -I"$INC_LIBLOG" \
  -I"$INC_LIBBASE" \
  -I"$INC_LIBUTILS" \
  -I"$INC_LIBCUTILS" \
  -DLOG_TAG=\"bt_hci_waydroid\" \
  "$HAL/soft_hci.cpp" \
  "$HAL/BluetoothHci.cpp" \
  "$HAL/service.cpp" \
  -L"$SYSROOT_LIB" \
  -Wl,-rpath-link,"$SYSROOT_LIB" \
  -landroid.hardware.bluetooth@1.0 \
  -lhidlbase -lutils -lcutils -llog -lbase -lc++ \
  -o "$OUT"

echo "BUILT $OUT"
file "$OUT"
