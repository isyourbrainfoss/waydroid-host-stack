#!/usr/bin/env bash
# Cross-build the Soft HCI HAL (android.hardware.bluetooth@1.0-service.waydroid)
# for aarch64 Android API 33 (Lineage 20 / Waydroid) with the Android NDK.
#
# Inputs (fetch with guest/hal/fetch-hal-deps.sh):
#   ANDROID_NDK_HOME   NDK root (r26+; tested r28c)
#   HAL_DEPS           dir containing:
#       vndk/          AOSP prebuilts/vndk/v33 arm64/include tree
#       bt-gen/        hidl-gen C++ headers for android.hardware.bluetooth@1.0
#       lib64/         guest libs from the target system.img (link only):
#                      libhidlbase libutils libcutils liblog libbase libc++
#                      android.hardware.bluetooth@1.0
# Output: $HAL_BUILD_DIR/android.hardware.bluetooth@1.0-service.waydroid
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HAL="$ROOT/guest/hal"
DEPS="${HAL_DEPS:?set HAL_DEPS (see fetch-hal-deps.sh)}"
SCRATCH="${HAL_BUILD_DIR:-$ROOT/out/hal}"
NDK="${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
API=33
CXX="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${API}-clang++"
V="$DEPS/vndk"
G="$V/generated-headers/system/libhidl/transport"

mkdir -p "$SCRATCH"
OUT="$SCRATCH/android.hardware.bluetooth@1.0-service.waydroid"

# The guest's libhidlbase / generated HIDL libs are built against the platform
# libc++ (inline namespace std::__1), while NDK headers default to std::__ndk1.
# Re-point the NDK headers' ABI namespace so std::string etc. in HIDL
# signatures mangle like the platform and resolve against the guest libc++.so.
CFG="$SCRATCH/libcxx-platform"
mkdir -p "$CFG"
SYSROOT_CXX="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/c++/v1"
sed 's/^#define _LIBCPP_ABI_NAMESPACE .*/#define _LIBCPP_ABI_NAMESPACE __1/' \
  "$SYSROOT_CXX/__config_site" >"$CFG/__config_site"

INCS=(
  -I"$CFG"
  -I"$HAL"
  -I"$DEPS/bt-gen"
  -I"$G/base/1.0/android.hidl.base@1.0_genc++_headers/gen"
  -I"$G/manager/1.0/android.hidl.manager@1.0_genc++_headers/gen"
  -I"$G/manager/1.1/android.hidl.manager@1.1_genc++_headers/gen"
  -I"$G/manager/1.2/android.hidl.manager@1.2_genc++_headers/gen"
  -I"$G/safe_union/1.0/android.hidl.safe_union@1.0_genc++_headers/gen"
  -I"$V/system/libhidl/base/include"
  -I"$V/system/libhidl/transport/include"
  -I"$V/system/libfmq/include"
  -I"$V/system/libfmq/base"
  -I"$V/system/libhwbinder/include"
  -I"$V/system/logging/liblog/include_vndk"
  -I"$V/system/libbase/include"
  -I"$V/system/core/libutils/include"
  -I"$V/system/core/libcutils/include"
  -I"$V/system/core/libsystem/include"
)

# Link against the guest's own libc++ (libc++.so), not the NDK's libc++_shared.
"$CXX" -std=c++17 -O2 -fPIE -pie -Wall -fno-rtti \
  -nostdlib++ \
  "${INCS[@]}" \
  -DLOG_TAG=\"bt_hci_waydroid\" \
  "$HAL/soft_hci.cpp" \
  "$HAL/soft_hci_att.cpp" \
  "$HAL/bridge_ipc.cpp" \
  "$HAL/BluetoothHci.cpp" \
  "$HAL/service.cpp" \
  -L"$DEPS/lib64" \
  -Wl,-rpath-link,"$DEPS/lib64" \
  -Wl,--allow-shlib-undefined \
  -l:android.hardware.bluetooth@1.0.so \
  -l:libhidlbase.so -l:libutils.so -l:libcutils.so -l:liblog.so -l:libbase.so -l:libc++.so \
  -o "$OUT"

"$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" "$OUT"
echo "BUILT $OUT"
