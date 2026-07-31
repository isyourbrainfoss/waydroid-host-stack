// Minimal LE ATT server for Soft HCI — answers Fluoride GATT discovery/IO
// while the real radio link lives on host BlueZ.
#pragma once

#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

namespace waydroid_bt {

using Packet = std::vector<uint8_t>;

// Host-side GATT ops used while an LE link is open (UUID-based, not handles).
struct AttHostOps {
  // Blocking-ish: called from Soft HCI ACL path (off binder if possible).
  std::function<bool(const std::string& char_uuid, const std::string& service_uuid,
                     std::vector<uint8_t>* value)>
      read_char;
  std::function<bool(const std::string& char_uuid, const std::string& service_uuid,
                     const std::vector<uint8_t>& value, bool without_response)>
      write_char;
  std::function<bool(const std::string& char_uuid, const std::string& service_uuid, bool enable)>
      set_notify;
};

// Synthetic GATT database for one LE connection (handles assigned here).
class SoftAttLink {
 public:
  static constexpr uint16_t kDefaultHandle = 0x0040;
  static constexpr uint16_t kAttCid = 0x0004;

  void reset();
  void set_peer(const std::string& address_colon, uint8_t addr_type);
  // Soft HCI connection handle for this ACL (must be unique per concurrent link).
  void set_conn_handle(uint16_t handle);
  void set_host_ops(AttHostOps ops);
  // One characteristic from host GATT discover: uuid + Android property bitfield.
  // properties==0 means "unknown" — Soft ATT will apply UUID-based heuristics.
  struct CharSpec {
    std::string uuid;
    uint8_t properties = 0;
  };

  // Build table from host-discovered UUIDs (handles synthesized).
  // Each entry is (service_uuid, characteristics).
  void build_from_uuids(
      const std::vector<std::pair<std::string, std::vector<CharSpec>>>& services_with_chars);

  bool active() const;
  uint16_t conn_handle() const { return conn_handle_; }
  const std::string& peer() const { return peer_; }
  uint8_t peer_type() const { return peer_type_; }

  // HCI ACL data packet from stack (no packet indicator). May emit ACL replies
  // and HCI Number of Completed Packets via sinks.
  void on_acl_from_stack(const Packet& acl, const std::function<void(const Packet&)>& emit_acl,
                         const std::function<void(const Packet&)>& emit_hci_event);

  // Inject Handle Value Notification (e.g. pressure samples from host).
  void notify_value(const std::string& char_uuid, const std::vector<uint8_t>& value,
                    const std::function<void(const Packet&)>& emit_acl);

  // HCI LE Connection Complete success packet for this link.
  Packet make_connection_complete_success() const;

 private:
  struct Attr {
    uint16_t handle = 0;
    // 16-bit or 128-bit UUID as canonical lowercase string.
    std::string uuid;
    // GATT type of this attribute (declaration / value / CCCD).
    enum Kind { kPrimaryService, kCharacteristicDecl, kValue, kCccd } kind = kValue;
    uint16_t end_group = 0;     // for primary service
    uint8_t char_props = 0;     // for characteristic declaration
    uint16_t value_handle = 0;  // for characteristic declaration
    std::string service_uuid;   // owning service for value/cccd
    std::string char_uuid;      // for value/cccd
    std::vector<uint8_t> static_value;
  };

  void handle_att(const uint8_t* pdu, size_t len, const std::function<void(const Packet&)>& emit_acl);
  void send_att(const Packet& att_pdu, const std::function<void(const Packet&)>& emit_acl);
  void send_error(uint8_t req_opcode, uint16_t handle, uint8_t err,
                  const std::function<void(const Packet&)>& emit_acl);
  Packet make_acl(const Packet& l2cap_payload) const;
  Packet make_num_completed(uint16_t n) const;
  Attr* find_handle(uint16_t h);
  const Attr* find_handle(uint16_t h) const;
  Attr* find_value_by_char_uuid(const std::string& uuid);

  mutable std::mutex mu_;
  bool active_ = false;
  uint16_t conn_handle_ = kDefaultHandle;
  std::string peer_;
  uint8_t peer_type_ = 0;
  uint16_t att_mtu_ = 23;
  AttHostOps ops_;
  std::vector<Attr> attrs_;
};

// Helpers
std::string normalize_uuid(std::string u);
bool uuid_is_16(const std::string& u, uint16_t* out);
Packet uuid_to_bytes_le(const std::string& u);

}  // namespace waydroid_bt
