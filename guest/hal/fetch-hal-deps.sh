#!/bin/sh
# Fetch build inputs for guest/hal/build_ndk.sh into $HAL_DEPS (default out/hal-deps).
#
#   sh guest/hal/fetch-hal-deps.sh LIB64_DIR
#
# LIB64_DIR: guest libs dumped from the *target* Waydroid system.img (read-only,
# no mount needed), e.g. on the phone:
#   for l in libhidlbase libutils libcutils liblog libbase libc++ android.hardware.bluetooth@1.0; do
#     debugfs -R "dump /system/lib64/$l.so $PWD/lib64/$l.so" /var/lib/waydroid/images/system.img
#   done
# Downloads:
#   vndk/   AOSP platform/prebuilts/vndk/v33 arm64/include (gitiles archive)
#   bt-gen/ hidl-gen headers for android.hardware.bluetooth@1.0 (frozen HIDL
#           interface; from waydroid/android_prebuilts_vndk_v30, sparse clone)
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
DEPS="${HAL_DEPS:-$ROOT/out/hal-deps}"
LIB64="${1:?usage: $0 LIB64_DIR}"
mkdir -p "$DEPS/vndk"
if [ ! -d "$DEPS/vndk/system/libhidl" ]; then
	curl -fsSL "https://android.googlesource.com/platform/prebuilts/vndk/v33/+archive/refs/heads/main/arm64/include.tar.gz" |
		tar xz -C "$DEPS/vndk"
fi
if [ ! -d "$DEPS/v30" ]; then
	git clone -q --depth 1 --filter=blob:none --sparse \
		https://github.com/waydroid/android_prebuilts_vndk_v30 "$DEPS/v30"
	git -C "$DEPS/v30" sparse-checkout set \
		arm64/include/generated-headers/hardware/interfaces/bluetooth/1.0
fi
ln -sfn "$DEPS/v30/arm64/include/generated-headers/hardware/interfaces/bluetooth/1.0/android.hardware.bluetooth@1.0_genc++_headers/gen" "$DEPS/bt-gen"
mkdir -p "$DEPS/lib64"
for l in libhidlbase libutils libcutils liblog libbase libc++ android.hardware.bluetooth@1.0; do
	cp -f "$LIB64/$l.so" "$DEPS/lib64/$l.so"
done
echo "HAL_DEPS_OK $DEPS"
