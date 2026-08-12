// Minimal host-bridge IPC client (protocol v1) for Soft HCI LE scan bridging.
// Speaks length-prefixed protobuf Envelopes without linking libprotobuf.
#pragma once

#include <cstdint>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace waydroid_bt {

// Protobuf AddressType (waydroid_bt.v1) — NOT HCI LE Address_Type.
// See messages.proto: UNSPECIFIED=0, PUBLIC=1, RANDOM=2.
constexpr uint8_t kProtoAddrUnspecified = 0;
constexpr uint8_t kProtoAddrPublic = 1;
constexpr uint8_t kProtoAddrRandom = 2;

// HCI LE Advertising Report Address_Type (Core Spec Vol 4 Part E).
constexpr uint8_t kHciAddrPublic = 0x00;
constexpr uint8_t kHciAddrRandom = 0x01;

struct BridgeAdv {
  std::string address;  // "AA:BB:..."
  // Raw protobuf AddressType enum value from AdvReportEvent (1=PUBLIC, 2=RANDOM).
  // Convert with proto_address_type_to_hci() before HCI inject.
  uint8_t address_type = kProtoAddrUnspecified;
  int8_t rssi = 0;
  std::string name;
  bool connectable = true;
  std::vector<uint8_t> raw_adv;
  std::vector<uint8_t> manufacturer_data;
  std::vector<std::string> service_uuids;
};

// Map protocol AddressType → HCI LE Address_Type (pure; unit-tested).
// PUBLIC(1)→0x00, RANDOM(2)→0x01; anything else → public (0x00).
uint8_t proto_address_type_to_hci(uint8_t proto_address_type);

// Blocking client used from Soft HCI scan worker thread.
class BridgeIpc {
 public:
  BridgeIpc() = default;
  ~BridgeIpc();

  BridgeIpc(const BridgeIpc&) = delete;
  BridgeIpc& operator=(const BridgeIpc&) = delete;

  // Connect to unix stream socket (e.g. /run/waydroid-bt/host.sock).
  bool connect(const char* path);
  void close();
  bool connected() const;

  // Start LE scan (active). Returns session_id or 0 on failure.
  uint32_t start_le_scan(bool active = true);
  bool stop_le_scan(uint32_t session_id);

  // Wait up to timeout_ms for an AdvReportEvent. Returns true if filled.
  bool poll_adv(BridgeAdv& out, int timeout_ms);

  // Host-bridged LE connect + GATT (for Soft HCI LE Create Connection path).
  // Returns true if ConnectLe + GattDiscover + one characteristic read succeed.
  bool connect_le_gatt_probe(const std::string& address_colon, uint32_t timeout_ms,
                             std::string* device_id_out, std::string* gatt_summary_out);

  // Characteristic discovered on host (uuid + property bitfield from BlueZ).
  struct GattChar {
    std::string uuid;
    uint8_t properties = 0;  // Android BluetoothGattCharacteristic bits
  };

  // Connect + GATT discover; leaves host LE link open (no Disconnect).
  // Fills services tree for Soft HCI ATT cache. device_id is BlueZ address.
  bool connect_le_open(const std::string& address_colon, uint32_t timeout_ms,
                       std::string* device_id_out,
                       std::vector<std::pair<std::string, std::vector<GattChar>>>* services_out,
                       std::string* summary_out);
  bool gatt_read_uuid(const std::string& device_id, const std::string& char_uuid,
                      const std::string& service_uuid, std::vector<uint8_t>* value_out);
  bool gatt_write_uuid(const std::string& device_id, const std::string& char_uuid,
                       const std::string& service_uuid, const std::vector<uint8_t>& value,
                       bool without_response);
  bool gatt_set_notify_uuid(const std::string& device_id, const std::string& char_uuid,
                            const std::string& service_uuid, bool enable);
  bool disconnect_device(const std::string& device_id);

  // Wait up to timeout_ms for GattNotificationEvent (field 4 / event.gatt_notification).
  // Used by Soft HCI ATT bridge to inject Handle Value Notifications into Fluoride.
  // If device_id_filter is non-empty, only accept notifications for that host device
  // (multi-link isolation when host fans out events to every guest client).
  bool poll_gatt_notification(std::string* char_uuid_out, std::vector<uint8_t>* value_out,
                              int timeout_ms, const std::string& device_id_filter = {});

  // Pure helpers (unit-testable):
  static std::vector<uint8_t> encode_start_le_scan(uint64_t request_id, bool active);
  static std::vector<uint8_t> encode_stop_le_scan(uint64_t request_id, uint32_t session_id);
  static std::vector<uint8_t> encode_connect_le(uint64_t request_id, const std::string& address,
                                                uint32_t timeout_ms);
  static std::vector<uint8_t> encode_gatt_discover(uint64_t request_id, const std::string& device_id);
  static std::vector<uint8_t> encode_gatt_read(uint64_t request_id, const std::string& device_id,
                                               const std::string& char_uuid,
                                               const std::string& service_uuid);
  static std::vector<uint8_t> encode_disconnect(uint64_t request_id, const std::string& device_id);
  // Parse a single envelope payload (no 4-byte length prefix).
  static bool parse_start_le_scan_session(const uint8_t* data, size_t len, uint32_t* session_out);
  static bool parse_adv_report(const uint8_t* data, size_t len, BridgeAdv* out);
  static bool parse_response_ok(const uint8_t* data, size_t len);
  static bool parse_connect_le_device_id(const uint8_t* data, size_t len, std::string* device_id_out);
  static bool parse_gatt_discover_counts(const uint8_t* data, size_t len, size_t* services_out,
                                         size_t* chars_out);
  // services: vector of (service_uuid, characteristics with properties)
  static bool parse_gatt_discover_tree(
      const uint8_t* data, size_t len,
      std::vector<std::pair<std::string, std::vector<GattChar>>>* out);
  static bool parse_gatt_read_value(const uint8_t* data, size_t len, std::vector<uint8_t>* value_out);
  static bool parse_gatt_notification(const uint8_t* data, size_t len, std::string* char_uuid_out,
                                      std::vector<uint8_t>* value_out,
                                      std::string* device_id_out = nullptr);

 private:
  bool write_all(const uint8_t* data, size_t len);
  bool read_exact(uint8_t* data, size_t len);
  bool read_frame(std::vector<uint8_t>& payload);
  bool write_frame(const std::vector<uint8_t>& payload);

  // Close socket; caller must already hold io_mu_ (non-recursive).
  void close_locked();

  int fd_ = -1;
  uint64_t next_rid_ = 100;
  // Serialize request/response and notify poll on the same unix fd.
  mutable std::mutex io_mu_;
};

// Build AD structure bytes from name / manufacturer / service UUIDs when raw_adv empty.
std::vector<uint8_t> build_adv_payload(const BridgeAdv& adv);

// Parse "AA:BB:CC:DD:EE:FF" into 6 little-endian HCI address bytes.
bool parse_bd_addr(const std::string& s, uint8_t out[6]);

}  // namespace waydroid_bt
