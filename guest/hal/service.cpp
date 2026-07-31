#define LOG_TAG "android.hardware.bluetooth@1.0-service.waydroid"

#include <android/hardware/bluetooth/1.0/IBluetoothHci.h>
#include <hidl/HidlTransportSupport.h>
#include <log/log.h>

#include "BluetoothHci.h"

using android::OK;
using android::sp;
using android::status_t;
using android::hardware::configureRpcThreadpool;
using android::hardware::joinRpcThreadpool;
using android::hardware::bluetooth::V1_0::IBluetoothHci;
using android::hardware::bluetooth::V1_0::implementation::BluetoothHci;

int main() {
  configureRpcThreadpool(1, true /* callerWillJoin */);

  sp<IBluetoothHci> service = new BluetoothHci();
  status_t status = service->registerAsService();
  if (status != OK) {
    ALOGE("Cannot register bluetooth HIDL service (%d)", status);
    return 1;
  }
  ALOGI("Waydroid soft Bluetooth HCI HAL registered");
  joinRpcThreadpool();
  return 1;
}
