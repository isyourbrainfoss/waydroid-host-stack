#pragma once

#include <android/hardware/bluetooth/1.0/IBluetoothHci.h>
#include <hidl/MQDescriptor.h>
#include <hidl/Status.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <queue>
#include <string>
#include <thread>
#include <vector>

#include "bridge_ipc.h"
#include "soft_hci.h"
#include "soft_hci_att.h"

namespace android {
namespace hardware {
namespace bluetooth {
namespace V1_0 {
namespace implementation {

using ::android::sp;
using ::android::hardware::hidl_vec;
using ::android::hardware::Return;
using ::android::hardware::Void;

struct BluetoothHci : public IBluetoothHci {
  BluetoothHci();
  ~BluetoothHci();

  Return<void> initialize(const sp<IBluetoothHciCallbacks>& callback) override;
  Return<void> sendHciCommand(const hidl_vec<uint8_t>& command) override;
  Return<void> sendAclData(const hidl_vec<uint8_t>& data) override;
  Return<void> sendScoData(const hidl_vec<uint8_t>& data) override;
  Return<void> close() override;

 private:
  // One Soft ATT + host BlueZ bridge per concurrent LE peer.
  struct AttSession {
    uint16_t handle = 0;
    std::string peer;  // "AA:BB:..."
    waydroid_bt::SoftAttLink link;
    std::unique_ptr<waydroid_bt::BridgeIpc> ipc;
    std::string device_id;
    std::atomic<bool> notify_run{false};
    std::thread notify_thread;
  };

  struct PendingLeConn {
    uint8_t peer[6]{};
    uint8_t peer_type = 0;
  };

  void eventWorker();
  void enqueueEvent(waydroid_bt::Packet event);
  void enqueueAcl(waydroid_bt::Packet acl);
  void onScanEnable(bool enable);
  void scanWorker();
  void onLeCreateConnection(const uint8_t peer_addr_le[6], uint8_t peer_addr_type);
  void leConnectWorker();
  void attNotifyWorker(uint16_t handle);
  // Close one session. inject_hci_disconnect=false when Soft HCI already emits
  // Disconnection Complete (stack-initiated Disconnect).
  void closeAttSessionLocked(uint16_t handle, bool inject_hci_disconnect);
  void closeAllAttSessionsLocked(bool inject_hci_disconnect);
  uint16_t allocConnHandleLocked();
  AttSession* findSessionByPeerLocked(const std::string& peer);
  AttSession* findSessionByHandleLocked(uint16_t handle);
  static uint16_t aclHandleOf(const waydroid_bt::Packet& acl);

  std::mutex mu_;
  sp<IBluetoothHciCallbacks> callbacks_;
  waydroid_bt::SoftHci soft_;

  // Ordered event/ACL delivery off the binder/sendHciCommand thread.
  struct OutMsg {
    enum Type { kEvent, kAcl } type = kEvent;
    waydroid_bt::Packet data;
  };
  std::mutex q_mu_;
  std::condition_variable q_cv_;
  std::queue<OutMsg> out_q_;
  std::atomic<bool> stop_{false};
  std::thread event_thread_;

  // Host BlueZ LE scan bridge (StartLeScan / AdvReport → HCI LE Meta events).
  std::mutex scan_mu_;
  std::condition_variable scan_cv_;
  std::atomic<bool> scan_want_{false};
  std::atomic<bool> scan_running_{false};
  // Keep host discovery up after LE_Set_Scan_Enable(1) even if the stack
  // pulses enable off (GD reconfig / FBP). Flowlog scans for ~8s and matches
  // adv names starting with "PRS".
  std::chrono::steady_clock::time_point scan_hold_until_{};
  std::thread scan_thread_;

  // Host-bridged LE Create Connection queue (supports multi-device).
  std::mutex le_conn_mu_;
  std::condition_variable le_conn_cv_;
  std::queue<PendingLeConn> le_conn_queue_;
  std::thread le_conn_thread_;

  // Concurrent Soft ATT sessions keyed by HCI connection handle.
  std::mutex att_mu_;
  std::map<uint16_t, std::unique_ptr<AttSession>> att_sessions_;
  uint16_t next_conn_handle_{0x0040};
  static constexpr size_t kMaxAttSessions = 8;

  static constexpr const char* kBridgeSocket = "/run/waydroid-bt/host.sock";
  static constexpr const char* kBridgeSocketAlt = "/dev/socket/waydroid_bt";
};

}  // namespace implementation
}  // namespace V1_0
}  // namespace bluetooth
}  // namespace hardware
}  // namespace android
