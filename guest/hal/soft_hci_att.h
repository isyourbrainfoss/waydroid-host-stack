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

  // Introspection for unit tests / diagnostics (handle Soft ATT table).
  bool has_cccd_for_char(const std::string& char_uuid) const;
  uint8_t char_props_for_uuid(const std::string& char_uuid) const;
  size_t attr_count() const;

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
  // Queued Prepare Write Requests (ATT long/reliable write), executed on 0x18.
  struct PreparedWrite {
    uint16_t handle;
    uint16_t offset;
    std::vector<uint8_t> value;
  };
  std::vector<PreparedWrite> prepared_;
  std::vector<Attr> attrs_;
};

// Helpers
std::string normalize_uuid(std::string u);
bool uuid_is_16(const std::string& u, uint16_t* out);
Packet uuid_to_bytes_le(const std::string& u);

// Android BluetoothGattCharacteristic property bits (subset).
constexpr uint8_t kGattPropRead = 0x02;
constexpr uint8_t kGattPropWriteNr = 0x04;
constexpr uint8_t kGattPropWrite = 0x08;
constexpr uint8_t kGattPropNotify = 0x10;
constexpr uint8_t kGattPropIndicate = 0x20;

// Pure GATT property helpers (unit-tested). Host BlueZ flags win when non-zero.
// Heuristics apply only when host_properties == 0 (unknown / not reported).
uint8_t guess_char_properties(const std::string& char_uuid);
uint8_t resolve_char_properties(uint8_t host_properties, const std::string& char_uuid);
bool char_needs_cccd(uint8_t properties);

// Multi-link policy: connecting a different peer must not force-close others.
// Same peer reconnect may reuse; different peer always keeps existing links.
bool multi_link_preserves_other_peer(const std::string& existing_peer,
                                     const std::string& connecting_peer);

}  // namespace waydroid_bt
