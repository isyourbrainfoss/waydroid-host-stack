#include "soft_hci_att.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstring>

namespace waydroid_bt {
namespace {

uint16_t rd16(const uint8_t* p) {
  return static_cast<uint16_t>(p[0] | (static_cast<uint16_t>(p[1]) << 8));
}
void wr16(Packet& p, uint16_t v) {
  p.push_back(static_cast<uint8_t>(v & 0xff));
  p.push_back(static_cast<uint8_t>((v >> 8) & 0xff));
}

}  // namespace

std::string normalize_uuid(std::string u) {
  for (char& c : u) {
    c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  }
  // Expand 16-bit "180f" → Bluetooth base UUID.
  if (u.size() == 4) {
    return "0000" + u + "-0000-1000-8000-00805f9b34fb";
  }
  if (u.size() == 8 && u.find('-') == std::string::npos) {
    return u.substr(0, 8) + "-0000-1000-8000-00805f9b34fb";
  }
  return u;
}

bool uuid_is_16(const std::string& u, uint16_t* out) {
  const std::string n = normalize_uuid(u);
  // 0000xxxx-0000-1000-8000-00805f9b34fb
  if (n.size() == 36 && n.compare(9, 27, "0000-1000-8000-00805f9b34fb") == 0 &&
      n.compare(0, 4, "0000") == 0) {
    unsigned int v = 0;
    if (std::sscanf(n.c_str() + 4, "%4x", &v) == 1) {
      if (out) *out = static_cast<uint16_t>(v);
      return true;
    }
  }
  return false;
}

Packet uuid_to_bytes_le(const std::string& u) {
  // Always encode as 16-byte Bluetooth UUID in little-endian wire order.
  // Short 16-bit UUIDs are expanded to the Bluetooth base UUID first.
  // (Returning only 2 bytes here previously broke Read By Group Type when we
  // advertised all primary services as UUID-128 — 16-bit services were skipped.)
  std::string hex;
  for (char c : normalize_uuid(u)) {
    if (c != '-') hex.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(c))));
  }
  Packet p(16, 0);
  if (hex.size() != 32) return p;
  // Bluetooth stores UUID as little-endian of the big-endian byte string.
  for (int i = 0; i < 16; i++) {
    unsigned int b = 0;
    std::sscanf(hex.c_str() + i * 2, "%2x", &b);
    p[15 - i] = static_cast<uint8_t>(b);
  }
  return p;
}

void SoftAttLink::reset() {
  std::lock_guard<std::mutex> lock(mu_);
  active_ = false;
  peer_.clear();
  peer_type_ = 0;
  att_mtu_ = 23;
  attrs_.clear();
  ops_ = {};
}

void SoftAttLink::set_peer(const std::string& address_colon, uint8_t addr_type) {
  std::lock_guard<std::mutex> lock(mu_);
  peer_ = address_colon;
  peer_type_ = addr_type;
}

void SoftAttLink::set_conn_handle(uint16_t handle) {
  std::lock_guard<std::mutex> lock(mu_);
  conn_handle_ = handle;
}

void SoftAttLink::set_host_ops(AttHostOps ops) {
  std::lock_guard<std::mutex> lock(mu_);
  ops_ = std::move(ops);
}

uint8_t guess_char_properties(const std::string& char_uuid) {
  const std::string cu = normalize_uuid(char_uuid);
  // Common notify streams (only used when host reported properties==0).
  if (cu.find("873ae82b") != std::string::npos || cu.find("873ae829") != std::string::npos ||
      cu.find("2a19") != std::string::npos || cu.find("fff4") != std::string::npos ||
      cu.find("fff1") != std::string::npos || cu.find("fff2") != std::string::npos) {
    return static_cast<uint8_t>(kGattPropRead | kGattPropNotify);
  }
  if (cu.find("873ae82c") != std::string::npos || cu.find("873ae832") != std::string::npos ||
      cu.find("36f5") != std::string::npos || cu.find("fff3") != std::string::npos) {
    return static_cast<uint8_t>(kGattPropWrite | kGattPropWriteNr);
  }
  return kGattPropRead;
}

uint8_t resolve_char_properties(uint8_t host_properties, const std::string& char_uuid) {
  // Host BlueZ flags are authoritative when present. Do not OR in heuristic
  // notify bits on top of a non-zero host mask (that invented CCCDs for
  // read-only chars that merely shared a UUID substring).
  if (host_properties != 0) {
    return host_properties;
  }
  return guess_char_properties(char_uuid);
}

bool char_needs_cccd(uint8_t properties) {
  return (properties & (kGattPropNotify | kGattPropIndicate)) != 0;
}

bool multi_link_preserves_other_peer(const std::string& existing_peer,
                                     const std::string& connecting_peer) {
  // Same peer may reconnect/reuse; different peer must leave the other alone.
  if (existing_peer.empty() || connecting_peer.empty()) return true;
  return existing_peer != connecting_peer;
}

void SoftAttLink::build_from_uuids(
    const std::vector<std::pair<std::string, std::vector<CharSpec>>>& services_with_chars) {
  std::lock_guard<std::mutex> lock(mu_);
  attrs_.clear();
  uint16_t h = 1;

  auto add = [&](Attr a) {
    a.handle = h++;
    attrs_.push_back(std::move(a));
    return attrs_.back().handle;
  };

  // Always include Generic Access with Device Name for stack happiness.
  {
    Attr svc;
    svc.kind = Attr::kPrimaryService;
    svc.uuid = "00001800-0000-1000-8000-00805f9b34fb";
    const size_t svc_idx = attrs_.size();
    add(svc);
    Attr cdecl;
    cdecl.kind = Attr::kCharacteristicDecl;
    cdecl.uuid = "00002803-0000-1000-8000-00805f9b34fb";
    cdecl.char_props = kGattPropRead;
    cdecl.char_uuid = "00002a00-0000-1000-8000-00805f9b34fb";
    cdecl.service_uuid = svc.uuid;
    const size_t cd_idx = attrs_.size();
    add(cdecl);
    Attr val;
    val.kind = Attr::kValue;
    val.uuid = "00002a00-0000-1000-8000-00805f9b34fb";
    val.char_uuid = val.uuid;
    val.service_uuid = svc.uuid;
    val.static_value.assign({'B', 'T'});
    const uint16_t vh = add(val);
    attrs_[cd_idx].value_handle = vh;
    attrs_[svc_idx].end_group = vh;
  }

  for (const auto& svc_pair : services_with_chars) {
    const std::string su = normalize_uuid(svc_pair.first);
    // Skip GAP if already added.
    if (su == "00001800-0000-1000-8000-00805f9b34fb") continue;

    Attr svc;
    svc.kind = Attr::kPrimaryService;
    svc.uuid = su;
    const size_t svc_idx = attrs_.size();
    add(svc);

    for (const auto& ch : svc_pair.second) {
      const std::string cu = normalize_uuid(ch.uuid);
      const uint8_t props = resolve_char_properties(ch.properties, cu);

      Attr cdecl;
      cdecl.kind = Attr::kCharacteristicDecl;
      cdecl.uuid = "00002803-0000-1000-8000-00805f9b34fb";
      cdecl.char_props = props;
      cdecl.char_uuid = cu;
      cdecl.service_uuid = su;
      const size_t cd_idx = attrs_.size();
      add(cdecl);

      Attr val;
      val.kind = Attr::kValue;
      val.uuid = cu;
      val.char_uuid = cu;
      val.service_uuid = su;
      const uint16_t vh = add(val);
      attrs_[cd_idx].value_handle = vh;

      // notify (0x10) or indicate (0x20) → CCCD
      if (char_needs_cccd(props)) {
        Attr cccd;
        cccd.kind = Attr::kCccd;
        cccd.uuid = "00002902-0000-1000-8000-00805f9b34fb";
        cccd.char_uuid = cu;
        cccd.service_uuid = su;
        cccd.static_value = {0x00, 0x00};
        add(cccd);
      }
    }
    attrs_[svc_idx].end_group = attrs_.back().handle;
  }

  active_ = true;
  att_mtu_ = 23;
}

bool SoftAttLink::active() const {
  std::lock_guard<std::mutex> lock(mu_);
  return active_;
}

bool SoftAttLink::has_cccd_for_char(const std::string& char_uuid) const {
  const std::string n = normalize_uuid(char_uuid);
  std::lock_guard<std::mutex> lock(mu_);
  for (const auto& a : attrs_) {
    if (a.kind == Attr::kCccd && normalize_uuid(a.char_uuid) == n) return true;
  }
  return false;
}

uint8_t SoftAttLink::char_props_for_uuid(const std::string& char_uuid) const {
  const std::string n = normalize_uuid(char_uuid);
  std::lock_guard<std::mutex> lock(mu_);
  for (const auto& a : attrs_) {
    if (a.kind == Attr::kCharacteristicDecl && normalize_uuid(a.char_uuid) == n) {
      return a.char_props;
    }
  }
  return 0;
}

size_t SoftAttLink::attr_count() const {
  std::lock_guard<std::mutex> lock(mu_);
  return attrs_.size();
}

SoftAttLink::Attr* SoftAttLink::find_handle(uint16_t h) {
  for (auto& a : attrs_) {
    if (a.handle == h) return &a;
  }
  return nullptr;
}
const SoftAttLink::Attr* SoftAttLink::find_handle(uint16_t h) const {
  for (const auto& a : attrs_) {
    if (a.handle == h) return &a;
  }
  return nullptr;
}

SoftAttLink::Attr* SoftAttLink::find_value_by_char_uuid(const std::string& uuid) {
  const std::string n = normalize_uuid(uuid);
  for (auto& a : attrs_) {
    if (a.kind == Attr::kValue && normalize_uuid(a.char_uuid) == n) return &a;
  }
  return nullptr;
}

Packet SoftAttLink::make_connection_complete_success() const {
  // LE Meta / Connection Complete (sub 0x01) status=0 handle role atype addr ...
  Packet e;
  e.push_back(0x3E);
  e.push_back(0x13);
  e.push_back(0x01);
  e.push_back(0x00);  // status success
  e.push_back(static_cast<uint8_t>(conn_handle_ & 0xff));
  e.push_back(static_cast<uint8_t>((conn_handle_ >> 8) & 0xff));
  e.push_back(0x00);  // master
  e.push_back(peer_type_);
  // Peer address in HCI LE order — parse from peer_ AA:BB:...
  unsigned int b[6] = {};
  std::sscanf(peer_.c_str(), "%02x:%02x:%02x:%02x:%02x:%02x", &b[0], &b[1], &b[2], &b[3], &b[4],
              &b[5]);
  for (int i = 0; i < 6; i++) {
    e.push_back(static_cast<uint8_t>(b[5 - i]));
  }
  e.push_back(0x18);
  e.push_back(0x00);  // interval
  e.push_back(0x00);
  e.push_back(0x00);  // latency
  e.push_back(0x48);
  e.push_back(0x00);  // supervision
  e.push_back(0x00);  // MCA
  e[1] = static_cast<uint8_t>(e.size() - 2);
  return e;
}

Packet SoftAttLink::make_acl(const Packet& l2cap_payload) const {
  // HCI ACL: handle | PB=10 (start auto-flushable) | BC=00, dlen, data
  Packet a;
  const uint16_t hdr = static_cast<uint16_t>((conn_handle_ & 0x0fff) | (0x2u << 12));
  wr16(a, hdr);
  wr16(a, static_cast<uint16_t>(l2cap_payload.size()));
  a.insert(a.end(), l2cap_payload.begin(), l2cap_payload.end());
  return a;
}

Packet SoftAttLink::make_num_completed(uint16_t n) const {
  // Event 0x13 Number Of Completed Packets
  Packet e;
  e.push_back(0x13);
  e.push_back(5);
  e.push_back(1);  // number of handles
  wr16(e, conn_handle_);
  wr16(e, n);
  return e;
}

void SoftAttLink::send_att(const Packet& att_pdu, const std::function<void(const Packet&)>& emit_acl) {
  Packet l2;
  wr16(l2, static_cast<uint16_t>(att_pdu.size()));
  wr16(l2, kAttCid);
  l2.insert(l2.end(), att_pdu.begin(), att_pdu.end());
  emit_acl(make_acl(l2));
}

void SoftAttLink::send_error(uint8_t req_opcode, uint16_t handle, uint8_t err,
                             const std::function<void(const Packet&)>& emit_acl) {
  Packet p;
  p.push_back(0x01);
  p.push_back(req_opcode);
  wr16(p, handle);
  p.push_back(err);
  send_att(p, emit_acl);
}

void SoftAttLink::on_acl_from_stack(const Packet& acl,
                                    const std::function<void(const Packet&)>& emit_acl,
                                    const std::function<void(const Packet&)>& emit_hci_event) {
  if (acl.size() < 4) return;
  // Credit host for this ACL packet.
  emit_hci_event(make_num_completed(1));

  const uint16_t dlen = rd16(acl.data() + 2);
  if (acl.size() < 4u + dlen || dlen < 4) return;
  const uint8_t* l2 = acl.data() + 4;
  const uint16_t l2_len = rd16(l2);
  const uint16_t cid = rd16(l2 + 2);
  if (cid != kAttCid || l2_len + 4 > dlen) return;
  handle_att(l2 + 4, l2_len, emit_acl);
}

void SoftAttLink::handle_att(const uint8_t* pdu, size_t len,
                             const std::function<void(const Packet&)>& emit_acl) {
  if (len < 1) return;
  const uint8_t op = pdu[0];
  std::lock_guard<std::mutex> lock(mu_);
  if (!active_) return;

  // Exchange MTU Request
  if (op == 0x02 && len >= 3) {
    uint16_t client_mtu = rd16(pdu + 1);
    if (client_mtu < 23) client_mtu = 23;
    if (client_mtu > 517) client_mtu = 517;
    att_mtu_ = client_mtu;
    Packet rsp;
    rsp.push_back(0x03);
    wr16(rsp, att_mtu_);
    send_att(rsp, emit_acl);
    return;
  }

  // Read By Group Type Request (Primary Service 0x2800)
  if (op == 0x10 && len >= 7) {
    const uint16_t start = rd16(pdu + 1);
    const uint16_t end = rd16(pdu + 3);
    uint16_t group_uuid = 0;
    if (len == 7) {
      group_uuid = rd16(pdu + 5);
    } else {
      // 128-bit group type not used for primary service discovery.
      send_error(op, start, 0x0A /* attr not found */, emit_acl);
      return;
    }
    if (group_uuid != 0x2800) {
      send_error(op, start, 0x0A, emit_acl);
      return;
    }
    // Always emit UUID-128 format (start+end+uuid128 = 20). Mixing 16-bit and
    // 128-bit service UUIDs in one ATT response is illegal; previously we
    // skipped 128-bit Pressensor services when 16-bit GAP/Battery appeared
    // first — Flowlog then reported "pressure characteristics not found".
    Packet rsp;
    rsp.push_back(0x11);  // Read By Group Type Response
    rsp.push_back(20);    // each: handle(2)+end(2)+uuid128(16)
    bool any = false;
    // ATT MTU is full PDU size including opcode.
    for (const auto& a : attrs_) {
      if (a.kind != Attr::kPrimaryService) continue;
      if (a.handle < start || a.handle > end) continue;
      if (rsp.size() + 20 > att_mtu_) break;
      wr16(rsp, a.handle);
      wr16(rsp, a.end_group ? a.end_group : a.handle);
      Packet ub = uuid_to_bytes_le(a.uuid);
      if (ub.size() != 16) continue;
      rsp.insert(rsp.end(), ub.begin(), ub.end());
      any = true;
    }
    if (!any) {
      send_error(op, start, 0x0A, emit_acl);
      return;
    }
    send_att(rsp, emit_acl);
    return;
  }

  // Read By Type Request (Characteristic 0x2803 or CCCD 0x2902 etc.)
  if (op == 0x08 && len >= 7) {
    const uint16_t start = rd16(pdu + 1);
    const uint16_t end = rd16(pdu + 3);
    uint16_t type16 = 0;
    bool type_is_16 = (len == 7);
    if (type_is_16) type16 = rd16(pdu + 5);
    Packet rsp;
    rsp.push_back(0x09);
    // characteristic declaration value = props(1)+value_handle(2)+uuid
    bool any = false;
    uint8_t pair_len = 0;
    for (const auto& a : attrs_) {
      if (a.handle < start || a.handle > end) continue;
      if (type_is_16 && type16 == 0x2803 && a.kind == Attr::kCharacteristicDecl) {
        // Always UUID-128 in characteristic declaration value so pair size is
        // constant (handle+props+value_handle+uuid128 = 21). Mixing 16/128
        // skips Pressensor chars after Battery Level.
        Packet uuidb = uuid_to_bytes_le(a.char_uuid);
        if (uuidb.size() != 16) continue;
        const uint8_t full = 21;  // handle(2)+props(1)+vh(2)+uuid128(16)
        if (!any) {
          pair_len = full;
          rsp.push_back(pair_len);
        } else if (pair_len != full) {
          continue;
        }
        if (rsp.size() + full > att_mtu_) break;
        wr16(rsp, a.handle);
        rsp.push_back(a.char_props);
        wr16(rsp, a.value_handle);
        rsp.insert(rsp.end(), uuidb.begin(), uuidb.end());
        any = true;
      } else if (type_is_16 && type16 == 0x2800 && a.kind == Attr::kPrimaryService) {
        // unusual
      } else if (type_is_16 && type16 == 0x2902 && a.kind == Attr::kCccd) {
        const uint8_t full = 4;  // handle(2)+value(2)
        if (!any) {
          pair_len = full;
          rsp.push_back(pair_len);
        } else if (pair_len != full) continue;
        wr16(rsp, a.handle);
        rsp.push_back(a.static_value.size() > 0 ? a.static_value[0] : 0);
        rsp.push_back(a.static_value.size() > 1 ? a.static_value[1] : 0);
        any = true;
      }
    }
    if (!any) {
      send_error(op, start, 0x0A, emit_acl);
      return;
    }
    send_att(rsp, emit_acl);
    return;
  }

  // Find Information Request
  if (op == 0x04 && len >= 5) {
    const uint16_t start = rd16(pdu + 1);
    const uint16_t end = rd16(pdu + 3);
    Packet rsp;
    rsp.push_back(0x05);
    rsp.push_back(0x01);  // format 16-bit UUIDs first
    bool any = false;
    bool use128 = false;
    for (const auto& a : attrs_) {
      if (a.handle < start || a.handle > end) continue;
      uint16_t u16 = 0;
      const bool is16 = uuid_is_16(a.uuid, &u16);
      if (!any) {
        use128 = !is16;
        rsp[1] = use128 ? 0x02 : 0x01;
      } else if (use128 == is16) {
        continue;
      }
      wr16(rsp, a.handle);
      if (is16 && !use128) {
        wr16(rsp, u16);
      } else {
        Packet ub = uuid_to_bytes_le(a.uuid);
        rsp.insert(rsp.end(), ub.begin(), ub.end());
      }
      any = true;
    }
    if (!any) {
      send_error(op, start, 0x0A, emit_acl);
      return;
    }
    send_att(rsp, emit_acl);
    return;
  }

  // Read Request
  if (op == 0x0A && len >= 3) {
    const uint16_t handle = rd16(pdu + 1);
    Attr* a = find_handle(handle);
    if (!a) {
      send_error(op, handle, 0x0A, emit_acl);
      return;
    }
    Packet value;
    if (a->kind == Attr::kPrimaryService) {
      value = uuid_to_bytes_le(a->uuid);
    } else if (a->kind == Attr::kCharacteristicDecl) {
      value.push_back(a->char_props);
      wr16(value, a->value_handle);
      Packet ub = uuid_to_bytes_le(a->char_uuid);
      value.insert(value.end(), ub.begin(), ub.end());
    } else if (a->kind == Attr::kCccd) {
      value = a->static_value;
      if (value.size() < 2) value = {0, 0};
    } else if (a->kind == Attr::kValue) {
      if (!a->static_value.empty() && !ops_.read_char) {
        value = a->static_value;
      } else if (ops_.read_char) {
        std::vector<uint8_t> v;
        if (ops_.read_char(a->char_uuid, a->service_uuid, &v)) {
          value = std::move(v);
        } else if (!a->static_value.empty()) {
          value = a->static_value;
        } else {
          value = {0};
        }
      } else {
        value = a->static_value.empty() ? std::vector<uint8_t>{0} : a->static_value;
      }
    }
    Packet rsp;
    rsp.push_back(0x0B);
    // Truncate to MTU-1
    const size_t maxv = att_mtu_ > 1 ? att_mtu_ - 1 : 22;
    if (value.size() > maxv) value.resize(maxv);
    rsp.insert(rsp.end(), value.begin(), value.end());
    send_att(rsp, emit_acl);
    return;
  }

  // Write Request / Command
  if ((op == 0x12 || op == 0x52) && len >= 3) {
    const uint16_t handle = rd16(pdu + 1);
    Attr* a = find_handle(handle);
    if (!a) {
      if (op == 0x12) send_error(op, handle, 0x0A, emit_acl);
      return;
    }
    std::vector<uint8_t> value(pdu + 3, pdu + len);
    if (a->kind == Attr::kCccd) {
      a->static_value = value;
      // bit0=notify, bit1=indicate — both need host StartNotify
      const bool enable = value.size() >= 1 && (value[0] & 0x03) != 0;
      const std::string cu = a->char_uuid;
      const std::string su = a->service_uuid;
      auto set_notify = ops_.set_notify;
      if (set_notify) {
        // Blocking host IPC while holding SoftAtt mu_ is OK: attNotifyWorker
        // only needs the lock after a full notification is parsed.
        (void)set_notify(cu, su, enable);
      }
      if (op == 0x12) {
        Packet rsp;
        rsp.push_back(0x13);
        send_att(rsp, emit_acl);
      }
      return;
    }
    if (a->kind == Attr::kValue && ops_.write_char) {
      ops_.write_char(a->char_uuid, a->service_uuid, value, op == 0x52);
    }
    if (op == 0x12) {
      Packet rsp;
      rsp.push_back(0x13);
      send_att(rsp, emit_acl);
    }
    return;
  }

  // Unsupported
  send_error(op, 0x0000, 0x06 /* Request Not Supported */, emit_acl);
}

void SoftAttLink::notify_value(const std::string& char_uuid, const std::vector<uint8_t>& value,
                               const std::function<void(const Packet&)>& emit_acl) {
  std::lock_guard<std::mutex> lock(mu_);
  if (!active_) return;
  Attr* val = find_value_by_char_uuid(char_uuid);
  if (!val) return;
  // Check CCCD enabled (notify bit0 or indicate bit1)
  bool enabled = false;
  for (const auto& a : attrs_) {
    if (a.kind == Attr::kCccd && normalize_uuid(a.char_uuid) == normalize_uuid(char_uuid)) {
      if (!a.static_value.empty() && (a.static_value[0] & 0x03)) enabled = true;
      break;
    }
  }
  if (!enabled) return;
  Packet att;
  att.push_back(0x1B);  // Handle Value Notification
  wr16(att, val->handle);
  const size_t maxv = att_mtu_ > 3 ? att_mtu_ - 3 : 20;
  size_t n = value.size() < maxv ? value.size() : maxv;
  att.insert(att.end(), value.begin(), value.begin() + static_cast<std::ptrdiff_t>(n));
  send_att(att, emit_acl);
}

}  // namespace waydroid_bt
