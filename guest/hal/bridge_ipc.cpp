#include "bridge_ipc.h"

#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace waydroid_bt {
namespace {

void put_varint(std::vector<uint8_t>& out, uint64_t v) {
  while (v >= 0x80) {
    out.push_back(static_cast<uint8_t>((v & 0x7f) | 0x80));
    v >>= 7;
  }
  out.push_back(static_cast<uint8_t>(v));
}

void put_key(std::vector<uint8_t>& out, uint32_t field, uint32_t wire) {
  put_varint(out, (static_cast<uint64_t>(field) << 3) | wire);
}

void put_bytes(std::vector<uint8_t>& out, uint32_t field, const uint8_t* data, size_t len) {
  put_key(out, field, 2);
  put_varint(out, len);
  out.insert(out.end(), data, data + len);
}

void put_submsg(std::vector<uint8_t>& out, uint32_t field, const std::vector<uint8_t>& msg) {
  put_bytes(out, field, msg.data(), msg.size());
}

bool read_varint(const uint8_t* data, size_t len, size_t& i, uint64_t& v) {
  v = 0;
  int shift = 0;
  while (i < len) {
    uint8_t b = data[i++];
    v |= static_cast<uint64_t>(b & 0x7f) << shift;
    if ((b & 0x80) == 0) {
      return true;
    }
    shift += 7;
    if (shift > 63) {
      return false;
    }
  }
  return false;
}

bool skip_field(const uint8_t* data, size_t len, size_t& i, uint32_t wire) {
  switch (wire) {
    case 0: {
      uint64_t v;
      return read_varint(data, len, i, v);
    }
    case 1:
      if (i + 8 > len) return false;
      i += 8;
      return true;
    case 2: {
      uint64_t l;
      if (!read_varint(data, len, i, l)) return false;
      if (i + l > len) return false;
      i += static_cast<size_t>(l);
      return true;
    }
    case 5:
      if (i + 4 > len) return false;
      i += 4;
      return true;
    default:
      return false;
  }
}

}  // namespace

BridgeIpc::~BridgeIpc() { close(); }

void BridgeIpc::close_locked() {
  // Caller holds io_mu_. Do not lock again (mutex is non-recursive).
  pending_.clear();
  if (fd_ >= 0) {
    ::close(fd_);
    fd_ = -1;
  }
}

void BridgeIpc::close() {
  // Must serialize with poll/read/write (notify worker vs disconnect path).
  std::lock_guard<std::mutex> lock(io_mu_);
  close_locked();
}

bool BridgeIpc::connected() const {
  std::lock_guard<std::mutex> lock(io_mu_);
  return fd_ >= 0;
}

bool BridgeIpc::connect(const char* path) {
  close();  // public close() takes io_mu_ itself
  int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) {
    return false;
  }
  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  if (path == nullptr || std::strlen(path) >= sizeof(addr.sun_path)) {
    ::close(fd);
    return false;
  }
  std::strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
  if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
    ::close(fd);
    return false;
  }
  std::lock_guard<std::mutex> lock(io_mu_);
  fd_ = fd;
  return true;
}

bool BridgeIpc::write_all(const uint8_t* data, size_t len) {
  size_t off = 0;
  while (off < len) {
    ssize_t n = ::write(fd_, data + off, len - off);
    if (n < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    if (n == 0) return false;
    off += static_cast<size_t>(n);
  }
  return true;
}

bool BridgeIpc::read_exact(uint8_t* data, size_t len) {
  size_t off = 0;
  while (off < len) {
    ssize_t n = ::read(fd_, data + off, len - off);
    if (n < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    if (n == 0) return false;
    off += static_cast<size_t>(n);
  }
  return true;
}

bool BridgeIpc::write_frame(const std::vector<uint8_t>& payload) {
  uint32_t len = static_cast<uint32_t>(payload.size());
  uint8_t hdr[4] = {
      static_cast<uint8_t>(len & 0xff),
      static_cast<uint8_t>((len >> 8) & 0xff),
      static_cast<uint8_t>((len >> 16) & 0xff),
      static_cast<uint8_t>((len >> 24) & 0xff),
  };
  if (!write_all(hdr, 4)) return false;
  return write_all(payload.data(), payload.size());
}

bool BridgeIpc::read_frame(std::vector<uint8_t>& payload) {
  for (;;) {
    if (!read_frame_raw(payload)) return false;
    PendingNotification n;
    if (!parse_gatt_notification(payload.data(), payload.size(), &n.char_uuid, &n.value,
                                 &n.device_id)) {
      return true;
    }
    if (pending_.size() >= 512) pending_.pop_front();
    pending_.push_back(std::move(n));
  }
}

bool BridgeIpc::read_frame_raw(std::vector<uint8_t>& payload) {
  uint8_t hdr[4];
  if (!read_exact(hdr, 4)) return false;
  uint32_t len = static_cast<uint32_t>(hdr[0]) | (static_cast<uint32_t>(hdr[1]) << 8) |
                 (static_cast<uint32_t>(hdr[2]) << 16) | (static_cast<uint32_t>(hdr[3]) << 24);
  if (len > 4 * 1024 * 1024) return false;
  payload.resize(len);
  if (len == 0) return true;
  return read_exact(payload.data(), len);
}

std::vector<uint8_t> BridgeIpc::encode_start_le_scan(uint64_t request_id, bool active) {
  // StartLeScanRequest { active = 3 }
  std::vector<uint8_t> scan_req;
  if (active) {
    put_key(scan_req, 3, 0);
    put_varint(scan_req, 1);
  }
  // Request { start_le_scan = 4 }
  std::vector<uint8_t> req;
  put_submsg(req, 4, scan_req);
  // Envelope { request_id = 1, request = 2 }
  std::vector<uint8_t> env;
  put_key(env, 1, 0);
  put_varint(env, request_id);
  put_submsg(env, 2, req);
  return env;
}

std::vector<uint8_t> BridgeIpc::encode_stop_le_scan(uint64_t request_id, uint32_t session_id) {
  std::vector<uint8_t> stop;
  put_key(stop, 1, 0);
  put_varint(stop, session_id);
  std::vector<uint8_t> req;
  put_submsg(req, 5, stop);  // stop_le_scan = 5
  std::vector<uint8_t> env;
  put_key(env, 1, 0);
  put_varint(env, request_id);
  put_submsg(env, 2, req);
  return env;
}

bool BridgeIpc::parse_start_le_scan_session(const uint8_t* data, size_t len, uint32_t* session_out) {
  // Envelope → response(3) → start_le_scan(13) → session_id(1)
  size_t i = 0;
  while (i < len) {
    uint64_t key;
    if (!read_varint(data, len, i, key)) return false;
    uint32_t field = static_cast<uint32_t>(key >> 3);
    uint32_t wire = static_cast<uint32_t>(key & 7);
    if (field == 3 && wire == 2) {
      uint64_t l;
      if (!read_varint(data, len, i, l)) return false;
      if (i + l > len) return false;
      const uint8_t* resp = data + i;
      size_t rlen = static_cast<size_t>(l);
      i += rlen;
      // Response fields
      size_t j = 0;
      int32_t error = 0;
      while (j < rlen) {
        uint64_t k2;
        if (!read_varint(resp, rlen, j, k2)) return false;
        uint32_t f2 = static_cast<uint32_t>(k2 >> 3);
        uint32_t w2 = static_cast<uint32_t>(k2 & 7);
        if (f2 == 1 && w2 == 0) {
          uint64_t ev;
          if (!read_varint(resp, rlen, j, ev)) return false;
          error = static_cast<int32_t>(ev);
        } else if (f2 == 13 && w2 == 2) {
          uint64_t l2;
          if (!read_varint(resp, rlen, j, l2)) return false;
          if (j + l2 > rlen) return false;
          const uint8_t* sl = resp + j;
          size_t slen = static_cast<size_t>(l2);
          j += slen;
          size_t k = 0;
          while (k < slen) {
            uint64_t k3;
            if (!read_varint(sl, slen, k, k3)) return false;
            uint32_t f3 = static_cast<uint32_t>(k3 >> 3);
            uint32_t w3 = static_cast<uint32_t>(k3 & 7);
            if (f3 == 1 && w3 == 0) {
              uint64_t sid;
              if (!read_varint(sl, slen, k, sid)) return false;
              if (error == 0 && session_out) {
                *session_out = static_cast<uint32_t>(sid);
                return true;
              }
            } else if (!skip_field(sl, slen, k, w3)) {
              return false;
            }
          }
        } else if (!skip_field(resp, rlen, j, w2)) {
          return false;
        }
      }
      return false;
    }
    if (!skip_field(data, len, i, wire)) return false;
  }
  return false;
}

bool BridgeIpc::parse_adv_report(const uint8_t* data, size_t len, BridgeAdv* out) {
  if (!out) return false;
  // Envelope → event(4) → adv_report(2)
  size_t i = 0;
  while (i < len) {
    uint64_t key;
    if (!read_varint(data, len, i, key)) return false;
    uint32_t field = static_cast<uint32_t>(key >> 3);
    uint32_t wire = static_cast<uint32_t>(key & 7);
    if (field == 4 && wire == 2) {
      uint64_t l;
      if (!read_varint(data, len, i, l)) return false;
      if (i + l > len) return false;
      const uint8_t* ev = data + i;
      size_t elen = static_cast<size_t>(l);
      i += elen;
      size_t j = 0;
      while (j < elen) {
        uint64_t k2;
        if (!read_varint(ev, elen, j, k2)) return false;
        uint32_t f2 = static_cast<uint32_t>(k2 >> 3);
        uint32_t w2 = static_cast<uint32_t>(k2 & 7);
        if (f2 == 2 && w2 == 2) {
          uint64_t l2;
          if (!read_varint(ev, elen, j, l2)) return false;
          if (j + l2 > elen) return false;
          const uint8_t* ar = ev + j;
          size_t alen = static_cast<size_t>(l2);
          j += alen;
          BridgeAdv adv;
          size_t k = 0;
          while (k < alen) {
            uint64_t k3;
            if (!read_varint(ar, alen, k, k3)) return false;
            uint32_t f3 = static_cast<uint32_t>(k3 >> 3);
            uint32_t w3 = static_cast<uint32_t>(k3 & 7);
            if (f3 == 2 && w3 == 2) {
              uint64_t l3;
              if (!read_varint(ar, alen, k, l3)) return false;
              if (k + l3 > alen) return false;
              const uint8_t* ba = ar + k;
              size_t bl = static_cast<size_t>(l3);
              k += bl;
              size_t m = 0;
              while (m < bl) {
                uint64_t k4;
                if (!read_varint(ba, bl, m, k4)) return false;
                uint32_t f4 = static_cast<uint32_t>(k4 >> 3);
                uint32_t w4 = static_cast<uint32_t>(k4 & 7);
                if (f4 == 1 && w4 == 2) {
                  uint64_t l4;
                  if (!read_varint(ba, bl, m, l4)) return false;
                  if (m + l4 > bl) return false;
                  adv.address.assign(reinterpret_cast<const char*>(ba + m), static_cast<size_t>(l4));
                  m += static_cast<size_t>(l4);
                } else if (f4 == 2 && w4 == 0) {
                  uint64_t at;
                  if (!read_varint(ba, bl, m, at)) return false;
                  adv.address_type = static_cast<uint8_t>(at);
                } else if (!skip_field(ba, bl, m, w4)) {
                  return false;
                }
              }
            } else if (f3 == 3 && w3 == 0) {
              uint64_t rssi;
              if (!read_varint(ar, alen, k, rssi)) return false;
              adv.rssi = static_cast<int8_t>(static_cast<int32_t>(rssi));
            } else if (f3 == 4 && w3 == 2) {
              uint64_t l3;
              if (!read_varint(ar, alen, k, l3)) return false;
              if (k + l3 > alen) return false;
              adv.name.assign(reinterpret_cast<const char*>(ar + k), static_cast<size_t>(l3));
              k += static_cast<size_t>(l3);
            } else if (f3 == 5 && w3 == 0) {
              uint64_t c;
              if (!read_varint(ar, alen, k, c)) return false;
              adv.connectable = c != 0;
            } else if (f3 == 6 && w3 == 2) {
              uint64_t l3;
              if (!read_varint(ar, alen, k, l3)) return false;
              if (k + l3 > alen) return false;
              adv.manufacturer_data.assign(ar + k, ar + k + static_cast<size_t>(l3));
              k += static_cast<size_t>(l3);
            } else if (f3 == 8 && w3 == 2) {
              uint64_t l3;
              if (!read_varint(ar, alen, k, l3)) return false;
              if (k + l3 > alen) return false;
              adv.service_uuids.emplace_back(reinterpret_cast<const char*>(ar + k),
                                            static_cast<size_t>(l3));
              k += static_cast<size_t>(l3);
            } else if (f3 == 9 && w3 == 2) {
              uint64_t l3;
              if (!read_varint(ar, alen, k, l3)) return false;
              if (k + l3 > alen) return false;
              adv.raw_adv.assign(ar + k, ar + k + static_cast<size_t>(l3));
              k += static_cast<size_t>(l3);
            } else if (!skip_field(ar, alen, k, w3)) {
              return false;
            }
          }
          *out = std::move(adv);
          return true;
        }
        if (!skip_field(ev, elen, j, w2)) return false;
      }
      return false;
    }
    if (!skip_field(data, len, i, wire)) return false;
  }
  return false;
}

uint32_t BridgeIpc::start_le_scan(bool active) {
  if (fd_ < 0) return 0;
  uint64_t rid = next_rid_++;
  auto payload = encode_start_le_scan(rid, active);
  if (!write_frame(payload)) return 0;
  // Read until matching response (skip events)
  for (int tries = 0; tries < 32; tries++) {
    std::vector<uint8_t> frame;
    if (!read_frame(frame)) return 0;
    uint32_t session = 0;
    if (parse_start_le_scan_session(frame.data(), frame.size(), &session)) {
      return session;
    }
    // Might be unrelated event — ignore
  }
  return 0;
}

bool BridgeIpc::stop_le_scan(uint32_t session_id) {
  if (fd_ < 0) return false;
  uint64_t rid = next_rid_++;
  auto payload = encode_stop_le_scan(rid, session_id);
  if (!write_frame(payload)) return false;
  for (int tries = 0; tries < 64; tries++) {
    std::vector<uint8_t> frame;
    if (!read_frame(frame)) return false;
    // Response has field 3; events field 4. Accept any response as stop ack.
    size_t i = 0;
    while (i < frame.size()) {
      uint64_t key;
      if (!read_varint(frame.data(), frame.size(), i, key)) break;
      uint32_t field = static_cast<uint32_t>(key >> 3);
      uint32_t wire = static_cast<uint32_t>(key & 7);
      if (field == 3 && wire == 2) {
        return true;
      }
      if (!skip_field(frame.data(), frame.size(), i, wire)) break;
    }
  }
  return false;
}

bool BridgeIpc::poll_adv(BridgeAdv& out, int timeout_ms) {
  if (fd_ < 0) return false;
  pollfd pfd{};
  pfd.fd = fd_;
  pfd.events = POLLIN;
  int pr = ::poll(&pfd, 1, timeout_ms);
  if (pr < 0) {
    if (errno == EINTR) return false;
    close();
    return false;
  }
  if (pr == 0) return false;
  if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
    close();
    return false;
  }
  std::vector<uint8_t> frame;
  if (!read_frame(frame)) {
    // EOF / protocol error — force reconnect on next StartLeScan.
    close();
    return false;
  }
  return parse_adv_report(frame.data(), frame.size(), &out);
}

std::vector<uint8_t> BridgeIpc::encode_connect_le(uint64_t request_id, const std::string& address,
                                                  uint32_t timeout_ms) {
  // BtAddress { address=1 string, address_type=2 PUBLIC=1 }
  std::vector<uint8_t> bt_addr;
  put_key(bt_addr, 1, 2);
  put_varint(bt_addr, address.size());
  bt_addr.insert(bt_addr.end(), address.begin(), address.end());
  put_key(bt_addr, 2, 0);
  put_varint(bt_addr, 1);  // PUBLIC
  // ConnectLeRequest { address=1, timeout_ms=2 }
  std::vector<uint8_t> cle;
  put_submsg(cle, 1, bt_addr);
  if (timeout_ms != 0) {
    put_key(cle, 2, 0);
    put_varint(cle, timeout_ms);
  }
  // Request { connect_le = 6 }
  std::vector<uint8_t> req;
  put_submsg(req, 6, cle);
  std::vector<uint8_t> env;
  put_key(env, 1, 0);
  put_varint(env, request_id);
  put_submsg(env, 2, req);
  return env;
}

std::vector<uint8_t> BridgeIpc::encode_gatt_discover(uint64_t request_id,
                                                     const std::string& device_id) {
  std::vector<uint8_t> gd;
  put_key(gd, 1, 2);
  put_varint(gd, device_id.size());
  gd.insert(gd.end(), device_id.begin(), device_id.end());
  std::vector<uint8_t> req;
  put_submsg(req, 8, gd);  // gatt_discover = 8
  std::vector<uint8_t> env;
  put_key(env, 1, 0);
  put_varint(env, request_id);
  put_submsg(env, 2, req);
  return env;
}

std::vector<uint8_t> BridgeIpc::encode_gatt_read(uint64_t request_id, const std::string& device_id,
                                                 const std::string& char_uuid,
                                                 const std::string& service_uuid) {
  std::vector<uint8_t> gr;
  put_key(gr, 1, 2);
  put_varint(gr, device_id.size());
  gr.insert(gr.end(), device_id.begin(), device_id.end());
  put_key(gr, 2, 2);
  put_varint(gr, char_uuid.size());
  gr.insert(gr.end(), char_uuid.begin(), char_uuid.end());
  if (!service_uuid.empty()) {
    put_key(gr, 3, 2);
    put_varint(gr, service_uuid.size());
    gr.insert(gr.end(), service_uuid.begin(), service_uuid.end());
  }
  std::vector<uint8_t> req;
  put_submsg(req, 9, gr);  // gatt_read = 9
  std::vector<uint8_t> env;
  put_key(env, 1, 0);
  put_varint(env, request_id);
  put_submsg(env, 2, req);
  return env;
}

std::vector<uint8_t> BridgeIpc::encode_disconnect(uint64_t request_id,
                                                  const std::string& device_id) {
  std::vector<uint8_t> dr;
  put_key(dr, 1, 2);
  put_varint(dr, device_id.size());
  dr.insert(dr.end(), device_id.begin(), device_id.end());
  std::vector<uint8_t> req;
  put_submsg(req, 7, dr);  // disconnect = 7
  std::vector<uint8_t> env;
  put_key(env, 1, 0);
  put_varint(env, request_id);
  put_submsg(env, 2, req);
  return env;
}

bool BridgeIpc::parse_response_ok(const uint8_t* data, size_t len) {
  // Response.error is proto3 enum default 0 (OK). Prost/protobuf omit default
  // fields on the wire, so a successful GattSetNotify/GattWrite response often
  // has no error field at all — only a result oneof. Treat missing error as OK.
  size_t i = 0;
  while (i < len) {
    uint64_t key;
    if (!read_varint(data, len, i, key)) return false;
    uint32_t field = static_cast<uint32_t>(key >> 3);
    uint32_t wire = static_cast<uint32_t>(key & 7);
    if (field == 3 && wire == 2) {
      uint64_t l;
      if (!read_varint(data, len, i, l)) return false;
      if (i + l > len) return false;
      const uint8_t* resp = data + i;
      size_t rlen = static_cast<size_t>(l);
      size_t j = 0;
      bool saw_error = false;
      uint64_t err = 0;
      while (j < rlen) {
        uint64_t k2;
        if (!read_varint(resp, rlen, j, k2)) return false;
        uint32_t f2 = static_cast<uint32_t>(k2 >> 3);
        uint32_t w2 = static_cast<uint32_t>(k2 & 7);
        if (f2 == 1 && w2 == 0) {
          if (!read_varint(resp, rlen, j, err)) return false;
          saw_error = true;
          continue;
        }
        if (!skip_field(resp, rlen, j, w2)) return false;
      }
      if (saw_error) return err == 0;
      // No error field → proto3 default OK.
      return true;
    }
    if (!skip_field(data, len, i, wire)) return false;
  }
  return false;
}

bool BridgeIpc::parse_connect_le_device_id(const uint8_t* data, size_t len,
                                           std::string* device_id_out) {
  // Envelope → response(3) → connect_le(15) → device_id(1)
  size_t i = 0;
  while (i < len) {
    uint64_t key;
    if (!read_varint(data, len, i, key)) return false;
    uint32_t field = static_cast<uint32_t>(key >> 3);
    uint32_t wire = static_cast<uint32_t>(key & 7);
    if (field == 3 && wire == 2) {
      uint64_t l;
      if (!read_varint(data, len, i, l)) return false;
      if (i + l > len) return false;
      const uint8_t* resp = data + i;
      size_t rlen = static_cast<size_t>(l);
      size_t j = 0;
      // proto3 omits ErrorCode.OK (0) on the wire — default must be OK, not "unset".
      int32_t error = 0;
      std::string device_id;
      bool have_device = false;
      while (j < rlen) {
        uint64_t k2;
        if (!read_varint(resp, rlen, j, k2)) return false;
        uint32_t f2 = static_cast<uint32_t>(k2 >> 3);
        uint32_t w2 = static_cast<uint32_t>(k2 & 7);
        if (f2 == 1 && w2 == 0) {
          uint64_t ev;
          if (!read_varint(resp, rlen, j, ev)) return false;
          error = static_cast<int32_t>(ev);
        } else if (f2 == 15 && w2 == 2) {
          uint64_t l2;
          if (!read_varint(resp, rlen, j, l2)) return false;
          if (j + l2 > rlen) return false;
          const uint8_t* cl = resp + j;
          size_t clen = static_cast<size_t>(l2);
          j += clen;
          size_t k = 0;
          while (k < clen) {
            uint64_t k3;
            if (!read_varint(cl, clen, k, k3)) return false;
            uint32_t f3 = static_cast<uint32_t>(k3 >> 3);
            uint32_t w3 = static_cast<uint32_t>(k3 & 7);
            if (f3 == 1 && w3 == 2) {
              uint64_t l3;
              if (!read_varint(cl, clen, k, l3)) return false;
              if (k + l3 > clen) return false;
              device_id.assign(reinterpret_cast<const char*>(cl + k),
                               static_cast<size_t>(l3));
              have_device = true;
              k += static_cast<size_t>(l3);
            } else if (!skip_field(cl, clen, k, w3)) {
              return false;
            }
          }
        } else if (!skip_field(resp, rlen, j, w2)) {
          return false;
        }
      }
      if (error == 0 && have_device) {
        if (device_id_out) *device_id_out = device_id;
        return true;
      }
      return false;
    }
    if (!skip_field(data, len, i, wire)) return false;
  }
  return false;
}

bool BridgeIpc::parse_gatt_discover_counts(const uint8_t* data, size_t len, size_t* services_out,
                                           size_t* chars_out) {
  // Walk response gatt_discover(17) services(1) list; each service has characteristics(4).
  size_t i = 0;
  size_t services = 0;
  size_t chars = 0;
  while (i < len) {
    uint64_t key;
    if (!read_varint(data, len, i, key)) return false;
    uint32_t field = static_cast<uint32_t>(key >> 3);
    uint32_t wire = static_cast<uint32_t>(key & 7);
    if (field == 3 && wire == 2) {
      uint64_t l;
      if (!read_varint(data, len, i, l)) return false;
      if (i + l > len) return false;
      const uint8_t* resp = data + i;
      size_t rlen = static_cast<size_t>(l);
      size_t j = 0;
      while (j < rlen) {
        uint64_t k2;
        if (!read_varint(resp, rlen, j, k2)) return false;
        uint32_t f2 = static_cast<uint32_t>(k2 >> 3);
        uint32_t w2 = static_cast<uint32_t>(k2 & 7);
        if (f2 == 17 && w2 == 2) {
          uint64_t l2;
          if (!read_varint(resp, rlen, j, l2)) return false;
          if (j + l2 > rlen) return false;
          const uint8_t* gd = resp + j;
          size_t glen = static_cast<size_t>(l2);
          j += glen;
          size_t k = 0;
          while (k < glen) {
            uint64_t k3;
            if (!read_varint(gd, glen, k, k3)) return false;
            uint32_t f3 = static_cast<uint32_t>(k3 >> 3);
            uint32_t w3 = static_cast<uint32_t>(k3 & 7);
            if (f3 == 1 && w3 == 2) {
              uint64_t l3;
              if (!read_varint(gd, glen, k, l3)) return false;
              if (k + l3 > glen) return false;
              services++;
              // count characteristics field 4 inside service
              const uint8_t* svc = gd + k;
              size_t slen = static_cast<size_t>(l3);
              k += slen;
              size_t m = 0;
              while (m < slen) {
                uint64_t k4;
                if (!read_varint(svc, slen, m, k4)) break;
                uint32_t f4 = static_cast<uint32_t>(k4 >> 3);
                uint32_t w4 = static_cast<uint32_t>(k4 & 7);
                if (f4 == 4 && w4 == 2) {
                  uint64_t l4;
                  if (!read_varint(svc, slen, m, l4)) break;
                  if (m + l4 > slen) break;
                  chars++;
                  m += static_cast<size_t>(l4);
                } else if (!skip_field(svc, slen, m, w4)) {
                  break;
                }
              }
            } else if (!skip_field(gd, glen, k, w3)) {
              return false;
            }
          }
          if (services_out) *services_out = services;
          if (chars_out) *chars_out = chars;
          return services > 0;
        }
        if (!skip_field(resp, rlen, j, w2)) return false;
      }
      return false;
    }
    if (!skip_field(data, len, i, wire)) return false;
  }
  return false;
}

bool BridgeIpc::parse_gatt_discover_tree(
    const uint8_t* data, size_t len,
    std::vector<std::pair<std::string, std::vector<GattChar>>>* out) {
  if (!out) return false;
  out->clear();
  size_t i = 0;
  while (i < len) {
    uint64_t key;
    if (!read_varint(data, len, i, key)) return false;
    uint32_t field = static_cast<uint32_t>(key >> 3);
    uint32_t wire = static_cast<uint32_t>(key & 7);
    if (field == 3 && wire == 2) {
      uint64_t l;
      if (!read_varint(data, len, i, l)) return false;
      if (i + l > len) return false;
      const uint8_t* resp = data + i;
      size_t rlen = static_cast<size_t>(l);
      size_t j = 0;
      while (j < rlen) {
        uint64_t k2;
        if (!read_varint(resp, rlen, j, k2)) return false;
        uint32_t f2 = static_cast<uint32_t>(k2 >> 3);
        uint32_t w2 = static_cast<uint32_t>(k2 & 7);
        if (f2 == 17 && w2 == 2) {
          uint64_t l2;
          if (!read_varint(resp, rlen, j, l2)) return false;
          if (j + l2 > rlen) return false;
          const uint8_t* gd = resp + j;
          size_t glen = static_cast<size_t>(l2);
          j += glen;
          size_t k = 0;
          while (k < glen) {
            uint64_t k3;
            if (!read_varint(gd, glen, k, k3)) return false;
            uint32_t f3 = static_cast<uint32_t>(k3 >> 3);
            uint32_t w3 = static_cast<uint32_t>(k3 & 7);
            if (f3 == 1 && w3 == 2) {
              uint64_t l3;
              if (!read_varint(gd, glen, k, l3)) return false;
              if (k + l3 > glen) return false;
              const uint8_t* svc = gd + k;
              size_t slen = static_cast<size_t>(l3);
              k += slen;
              std::string suuid;
              std::vector<GattChar> chars;
              size_t m = 0;
              while (m < slen) {
                uint64_t k4;
                if (!read_varint(svc, slen, m, k4)) break;
                uint32_t f4 = static_cast<uint32_t>(k4 >> 3);
                uint32_t w4 = static_cast<uint32_t>(k4 & 7);
                if (f4 == 1 && w4 == 2) {
                  uint64_t l4;
                  if (!read_varint(svc, slen, m, l4)) break;
                  if (m + l4 > slen) break;
                  suuid.assign(reinterpret_cast<const char*>(svc + m), static_cast<size_t>(l4));
                  m += static_cast<size_t>(l4);
                } else if (f4 == 4 && w4 == 2) {
                  uint64_t l4;
                  if (!read_varint(svc, slen, m, l4)) break;
                  if (m + l4 > slen) break;
                  const uint8_t* ch = svc + m;
                  size_t clen = static_cast<size_t>(l4);
                  m += clen;
                  GattChar gc;
                  size_t n = 0;
                  while (n < clen) {
                    uint64_t k5;
                    if (!read_varint(ch, clen, n, k5)) break;
                    uint32_t f5 = static_cast<uint32_t>(k5 >> 3);
                    uint32_t w5 = static_cast<uint32_t>(k5 & 7);
                    if (f5 == 1 && w5 == 2) {
                      // uuid
                      uint64_t l5;
                      if (!read_varint(ch, clen, n, l5)) break;
                      if (n + l5 > clen) break;
                      gc.uuid.assign(reinterpret_cast<const char*>(ch + n),
                                     static_cast<size_t>(l5));
                      n += static_cast<size_t>(l5);
                    } else if (f5 == 3 && w5 == 0) {
                      // properties (varint)
                      uint64_t props = 0;
                      if (!read_varint(ch, clen, n, props)) break;
                      gc.properties = static_cast<uint8_t>(props & 0xff);
                    } else if (!skip_field(ch, clen, n, w5)) {
                      break;
                    }
                  }
                  if (!gc.uuid.empty()) {
                    chars.push_back(std::move(gc));
                  }
                } else if (!skip_field(svc, slen, m, w4)) {
                  break;
                }
              }
              if (!suuid.empty()) {
                out->emplace_back(std::move(suuid), std::move(chars));
              }
            } else if (!skip_field(gd, glen, k, w3)) {
              return false;
            }
          }
          return !out->empty();
        }
        if (!skip_field(resp, rlen, j, w2)) return false;
      }
      return false;
    }
    if (!skip_field(data, len, i, wire)) return false;
  }
  return false;
}

bool BridgeIpc::parse_gatt_read_value(const uint8_t* data, size_t len,
                                      std::vector<uint8_t>* value_out) {
  // response → gatt_read(18) → value(1) bytes
  size_t i = 0;
  while (i < len) {
    uint64_t key;
    if (!read_varint(data, len, i, key)) return false;
    uint32_t field = static_cast<uint32_t>(key >> 3);
    uint32_t wire = static_cast<uint32_t>(key & 7);
    if (field == 3 && wire == 2) {
      uint64_t l;
      if (!read_varint(data, len, i, l)) return false;
      if (i + l > len) return false;
      const uint8_t* resp = data + i;
      size_t rlen = static_cast<size_t>(l);
      size_t j = 0;
      while (j < rlen) {
        uint64_t k2;
        if (!read_varint(resp, rlen, j, k2)) return false;
        uint32_t f2 = static_cast<uint32_t>(k2 >> 3);
        uint32_t w2 = static_cast<uint32_t>(k2 & 7);
        if (f2 == 18 && w2 == 2) {
          uint64_t l2;
          if (!read_varint(resp, rlen, j, l2)) return false;
          if (j + l2 > rlen) return false;
          const uint8_t* gr = resp + j;
          size_t glen = static_cast<size_t>(l2);
          size_t k = 0;
          while (k < glen) {
            uint64_t k3;
            if (!read_varint(gr, glen, k, k3)) return false;
            uint32_t f3 = static_cast<uint32_t>(k3 >> 3);
            uint32_t w3 = static_cast<uint32_t>(k3 & 7);
            if (f3 == 1 && w3 == 2) {
              uint64_t l3;
              if (!read_varint(gr, glen, k, l3)) return false;
              if (k + l3 > glen) return false;
              if (value_out) {
                value_out->assign(gr + k, gr + k + static_cast<size_t>(l3));
              }
              return l3 > 0;
            }
            if (!skip_field(gr, glen, k, w3)) return false;
          }
          return false;
        }
        if (!skip_field(resp, rlen, j, w2)) return false;
      }
      return false;
    }
    if (!skip_field(data, len, i, wire)) return false;
  }
  return false;
}

bool BridgeIpc::connect_le_gatt_probe(const std::string& address_colon, uint32_t timeout_ms,
                                      std::string* device_id_out, std::string* gatt_summary_out) {
  if (fd_ < 0) return false;
  auto wait_response = [&](std::vector<uint8_t>& frame) -> bool {
    for (int tries = 0; tries < 128; tries++) {
      if (!read_frame(frame)) return false;
      // skip events (field 4)
      size_t i = 0;
      bool is_resp = false;
      while (i < frame.size()) {
        uint64_t key;
        if (!read_varint(frame.data(), frame.size(), i, key)) break;
        uint32_t field = static_cast<uint32_t>(key >> 3);
        uint32_t wire = static_cast<uint32_t>(key & 7);
        if (field == 3 && wire == 2) {
          is_resp = true;
          break;
        }
        if (!skip_field(frame.data(), frame.size(), i, wire)) break;
      }
      if (is_resp) return true;
    }
    return false;
  };

  uint64_t rid = next_rid_++;
  if (!write_frame(encode_connect_le(rid, address_colon, timeout_ms))) return false;
  std::vector<uint8_t> frame;
  if (!wait_response(frame)) return false;
  std::string device_id;
  if (!parse_connect_le_device_id(frame.data(), frame.size(), &device_id)) {
    if (gatt_summary_out) *gatt_summary_out = "CONNECT_FAIL";
    return false;
  }
  if (device_id_out) *device_id_out = device_id;

  rid = next_rid_++;
  if (!write_frame(encode_gatt_discover(rid, device_id))) {
    write_frame(encode_disconnect(next_rid_++, device_id));
    return false;
  }
  if (!wait_response(frame)) return false;
  size_t nsvc = 0, nch = 0;
  if (!parse_gatt_discover_counts(frame.data(), frame.size(), &nsvc, &nch)) {
    if (gatt_summary_out) {
      *gatt_summary_out = "GATT_DISCOVER_FAIL device=" + device_id;
    }
    write_frame(encode_disconnect(next_rid_++, device_id));
    return false;
  }

  // Device Name characteristic
  const char* char_uuid = "00002a00-0000-1000-8000-00805f9b34fb";
  const char* svc_uuid = "00001800-0000-1000-8000-00805f9b34fb";
  rid = next_rid_++;
  if (!write_frame(encode_gatt_read(rid, device_id, char_uuid, svc_uuid))) {
    write_frame(encode_disconnect(next_rid_++, device_id));
    return false;
  }
  if (!wait_response(frame)) return false;
  std::vector<uint8_t> value;
  if (!parse_gatt_read_value(frame.data(), frame.size(), &value)) {
    if (gatt_summary_out) {
      *gatt_summary_out = "GATT_READ_FAIL services=" + std::to_string(nsvc) +
                          " chars=" + std::to_string(nch);
    }
    write_frame(encode_disconnect(next_rid_++, device_id));
    return false;
  }

  write_frame(encode_disconnect(next_rid_++, device_id));
  wait_response(frame);  // best-effort

  if (gatt_summary_out) {
    *gatt_summary_out = "GATT_OK services=" + std::to_string(nsvc) + " chars=" + std::to_string(nch) +
                        " read_len=" + std::to_string(value.size()) + " device=" + device_id;
  }
  return true;
}

bool BridgeIpc::connect_le_open(
    const std::string& address_colon, uint32_t timeout_ms, std::string* device_id_out,
    std::vector<std::pair<std::string, std::vector<GattChar>>>* services_out,
    std::string* summary_out) {
  if (fd_ < 0) return false;
  auto wait_response = [&](std::vector<uint8_t>& frame) -> bool {
    for (int tries = 0; tries < 128; tries++) {
      if (!read_frame(frame)) return false;
      size_t i = 0;
      while (i < frame.size()) {
        uint64_t key;
        if (!read_varint(frame.data(), frame.size(), i, key)) break;
        uint32_t field = static_cast<uint32_t>(key >> 3);
        uint32_t wire = static_cast<uint32_t>(key & 7);
        if (field == 3 && wire == 2) return true;
        if (!skip_field(frame.data(), frame.size(), i, wire)) break;
      }
    }
    return false;
  };

  uint64_t rid = next_rid_++;
  if (!write_frame(encode_connect_le(rid, address_colon, timeout_ms))) return false;
  std::vector<uint8_t> frame;
  if (!wait_response(frame)) return false;
  std::string device_id;
  if (!parse_connect_le_device_id(frame.data(), frame.size(), &device_id)) {
    if (summary_out) *summary_out = "CONNECT_FAIL";
    return false;
  }
  if (device_id_out) *device_id_out = device_id;

  rid = next_rid_++;
  if (!write_frame(encode_gatt_discover(rid, device_id))) {
    write_frame(encode_disconnect(next_rid_++, device_id));
    return false;
  }
  if (!wait_response(frame)) return false;
  std::vector<std::pair<std::string, std::vector<GattChar>>> tree;
  if (!parse_gatt_discover_tree(frame.data(), frame.size(), &tree) || tree.empty()) {
    if (summary_out) *summary_out = "GATT_DISCOVER_FAIL device=" + device_id;
    write_frame(encode_disconnect(next_rid_++, device_id));
    return false;
  }
  if (services_out) *services_out = tree;
  if (summary_out) {
    size_t nch = 0;
    size_t nnotify = 0;
    for (const auto& s : tree) {
      nch += s.second.size();
      for (const auto& c : s.second) {
        if (c.properties & 0x30) nnotify++;
      }
    }
    *summary_out = "GATT_OPEN services=" + std::to_string(tree.size()) +
                   " chars=" + std::to_string(nch) +
                   " notifyish=" + std::to_string(nnotify) + " device=" + device_id;
  }
  // Leave host LE link open for Soft HCI ATT bridge.
  return true;
}

bool BridgeIpc::gatt_read_uuid(const std::string& device_id, const std::string& char_uuid,
                               const std::string& service_uuid, std::vector<uint8_t>* value_out) {
  std::lock_guard<std::mutex> lock(io_mu_);
  if (fd_ < 0) return false;
  uint64_t rid = next_rid_++;
  if (!write_frame(encode_gatt_read(rid, device_id, char_uuid, service_uuid))) return false;
  for (int tries = 0; tries < 64; tries++) {
    std::vector<uint8_t> frame;
    if (!read_frame(frame)) return false;
    size_t i = 0;
    bool is_resp = false;
    while (i < frame.size()) {
      uint64_t key;
      if (!read_varint(frame.data(), frame.size(), i, key)) break;
      uint32_t field = static_cast<uint32_t>(key >> 3);
      uint32_t wire = static_cast<uint32_t>(key & 7);
      if (field == 3 && wire == 2) {
        is_resp = true;
        break;
      }
      if (!skip_field(frame.data(), frame.size(), i, wire)) break;
    }
    if (!is_resp) continue;
    return parse_gatt_read_value(frame.data(), frame.size(), value_out);
  }
  return false;
}

bool BridgeIpc::gatt_write_uuid(const std::string& device_id, const std::string& char_uuid,
                                const std::string& service_uuid, const std::vector<uint8_t>& value,
                                bool without_response) {
  std::lock_guard<std::mutex> lock(io_mu_);
  if (fd_ < 0) return false;
  // Encode GattWriteRequest { device=1, char=2, service=3, value=4, without_response=5 }
  std::vector<uint8_t> gw;
  put_key(gw, 1, 2);
  put_varint(gw, device_id.size());
  gw.insert(gw.end(), device_id.begin(), device_id.end());
  put_key(gw, 2, 2);
  put_varint(gw, char_uuid.size());
  gw.insert(gw.end(), char_uuid.begin(), char_uuid.end());
  if (!service_uuid.empty()) {
    put_key(gw, 3, 2);
    put_varint(gw, service_uuid.size());
    gw.insert(gw.end(), service_uuid.begin(), service_uuid.end());
  }
  put_key(gw, 4, 2);
  put_varint(gw, value.size());
  gw.insert(gw.end(), value.begin(), value.end());
  if (without_response) {
    put_key(gw, 5, 0);
    put_varint(gw, 1);
  }
  std::vector<uint8_t> req;
  put_submsg(req, 10, gw);  // gatt_write = 10
  std::vector<uint8_t> env;
  put_key(env, 1, 0);
  put_varint(env, next_rid_++);
  put_submsg(env, 2, req);
  if (!write_frame(env)) return false;
  for (int tries = 0; tries < 64; tries++) {
    std::vector<uint8_t> frame;
    if (!read_frame(frame)) return false;
    if (parse_response_ok(frame.data(), frame.size()) ||
        parse_response_ok(frame.data(), frame.size())) {
      // parse_response_ok returns true for error==0
    }
    size_t i = 0;
    while (i < frame.size()) {
      uint64_t key;
      if (!read_varint(frame.data(), frame.size(), i, key)) break;
      uint32_t field = static_cast<uint32_t>(key >> 3);
      uint32_t wire = static_cast<uint32_t>(key & 7);
      if (field == 3 && wire == 2) return parse_response_ok(frame.data(), frame.size());
      if (!skip_field(frame.data(), frame.size(), i, wire)) break;
    }
  }
  return false;
}

bool BridgeIpc::gatt_set_notify_uuid(const std::string& device_id, const std::string& char_uuid,
                                     const std::string& service_uuid, bool enable) {
  std::lock_guard<std::mutex> lock(io_mu_);
  if (fd_ < 0) return false;
  std::vector<uint8_t> gn;
  put_key(gn, 1, 2);
  put_varint(gn, device_id.size());
  gn.insert(gn.end(), device_id.begin(), device_id.end());
  put_key(gn, 2, 2);
  put_varint(gn, char_uuid.size());
  gn.insert(gn.end(), char_uuid.begin(), char_uuid.end());
  if (!service_uuid.empty()) {
    put_key(gn, 3, 2);
    put_varint(gn, service_uuid.size());
    gn.insert(gn.end(), service_uuid.begin(), service_uuid.end());
  }
  put_key(gn, 4, 0);
  put_varint(gn, enable ? 1 : 0);
  std::vector<uint8_t> req;
  put_submsg(req, 11, gn);  // gatt_set_notify = 11
  std::vector<uint8_t> env;
  put_key(env, 1, 0);
  put_varint(env, next_rid_++);
  put_submsg(env, 2, req);
  if (!write_frame(env)) return false;
  for (int tries = 0; tries < 64; tries++) {
    std::vector<uint8_t> frame;
    if (!read_frame(frame)) return false;
    size_t i = 0;
    while (i < frame.size()) {
      uint64_t key;
      if (!read_varint(frame.data(), frame.size(), i, key)) break;
      uint32_t field = static_cast<uint32_t>(key >> 3);
      uint32_t wire = static_cast<uint32_t>(key & 7);
      if (field == 3 && wire == 2) {
        const bool ok = parse_response_ok(frame.data(), frame.size());
        // Logging via stderr is unavailable in HAL; return value is logged by Soft HCI ops.
        return ok;
      }
      // Skip unsolicited events (notifications) while waiting for set_notify ack.
      if (!skip_field(frame.data(), frame.size(), i, wire)) break;
    }
  }
  return false;
}

bool BridgeIpc::parse_gatt_notification(const uint8_t* data, size_t len, std::string* char_uuid_out,
                                        std::vector<uint8_t>* value_out, std::string* device_id_out) {
  // Envelope { event=4 { gatt_notification=4 { device=1, char=2, service=3, value=4 } } }
  size_t i = 0;
  while (i < len) {
    uint64_t key;
    if (!read_varint(data, len, i, key)) return false;
    uint32_t field = static_cast<uint32_t>(key >> 3);
    uint32_t wire = static_cast<uint32_t>(key & 7);
    if (field == 4 && wire == 2) {
      uint64_t l;
      if (!read_varint(data, len, i, l)) return false;
      if (i + l > len) return false;
      const uint8_t* ev = data + i;
      size_t elen = static_cast<size_t>(l);
      size_t j = 0;
      while (j < elen) {
        uint64_t k2;
        if (!read_varint(ev, elen, j, k2)) return false;
        uint32_t f2 = static_cast<uint32_t>(k2 >> 3);
        uint32_t w2 = static_cast<uint32_t>(k2 & 7);
        if (f2 == 4 && w2 == 2) {
          uint64_t l2;
          if (!read_varint(ev, elen, j, l2)) return false;
          if (j + l2 > elen) return false;
          const uint8_t* gn = ev + j;
          size_t glen = static_cast<size_t>(l2);
          size_t k = 0;
          std::string dev;
          std::string cu;
          std::vector<uint8_t> val;
          while (k < glen) {
            uint64_t k3;
            if (!read_varint(gn, glen, k, k3)) break;
            uint32_t f3 = static_cast<uint32_t>(k3 >> 3);
            uint32_t w3 = static_cast<uint32_t>(k3 & 7);
            if (f3 == 1 && w3 == 2) {
              uint64_t l3;
              if (!read_varint(gn, glen, k, l3)) break;
              if (k + l3 > glen) break;
              dev.assign(reinterpret_cast<const char*>(gn + k), static_cast<size_t>(l3));
              k += static_cast<size_t>(l3);
            } else if (f3 == 2 && w3 == 2) {
              uint64_t l3;
              if (!read_varint(gn, glen, k, l3)) break;
              if (k + l3 > glen) break;
              cu.assign(reinterpret_cast<const char*>(gn + k), static_cast<size_t>(l3));
              k += static_cast<size_t>(l3);
            } else if (f3 == 4 && w3 == 2) {
              uint64_t l3;
              if (!read_varint(gn, glen, k, l3)) break;
              if (k + l3 > glen) break;
              val.assign(gn + k, gn + k + static_cast<size_t>(l3));
              k += static_cast<size_t>(l3);
            } else if (!skip_field(gn, glen, k, w3)) {
              break;
            }
          }
          if (!cu.empty()) {
            if (char_uuid_out) *char_uuid_out = cu;
            if (value_out) *value_out = std::move(val);
            if (device_id_out) *device_id_out = std::move(dev);
            return true;
          }
          return false;
        }
        if (!skip_field(ev, elen, j, w2)) return false;
      }
      return false;
    }
    if (!skip_field(data, len, i, wire)) return false;
  }
  return false;
}

bool BridgeIpc::poll_gatt_notification(std::string* char_uuid_out, std::vector<uint8_t>* value_out,
                                       int timeout_ms, const std::string& device_id_filter) {
  // Try-lock so set_notify / read / write on the binder thread are not blocked.
  std::unique_lock<std::mutex> lock(io_mu_, std::try_to_lock);
  if (!lock.owns_lock()) {
    // Another request in flight; brief pause.
    ::poll(nullptr, 0, 20);
    return false;
  }
  std::string dev;
  std::string cu;
  std::vector<uint8_t> val;
  if (!pending_.empty()) {
    // Delivered in arrival order, ahead of anything still on the socket.
    dev = std::move(pending_.front().device_id);
    cu = std::move(pending_.front().char_uuid);
    val = std::move(pending_.front().value);
    pending_.pop_front();
  } else {
    if (fd_ < 0) return false;
    pollfd pfd{};
    pfd.fd = fd_;
    pfd.events = POLLIN;
    // Keep lock for poll+read; timeout is short (caller uses 200ms).
    int pr = ::poll(&pfd, 1, timeout_ms);
    if (pr <= 0) return false;
    if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
      // Already hold io_mu_; public close() would self-deadlock.
      close_locked();
      return false;
    }
    std::vector<uint8_t> frame;
    if (!read_frame_raw(frame)) {
      close_locked();
      return false;
    }
    if (!parse_gatt_notification(frame.data(), frame.size(), &cu, &val, &dev)) {
      return false;
    }
  }
  if (!device_id_filter.empty() && !dev.empty()) {
    // Case-insensitive match (BlueZ ids are typically uppercase addresses).
    std::string a = device_id_filter;
    std::string b = dev;
    for (char& c : a) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    for (char& c : b) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    if (a != b) {
      return false;  // notification for another multi-link peer
    }
  }
  if (char_uuid_out) *char_uuid_out = std::move(cu);
  if (value_out) *value_out = std::move(val);
  return true;
}

bool BridgeIpc::disconnect_device(const std::string& device_id) {
  // Serialize with poll_gatt_notification / gatt_* on the same unix fd.
  std::lock_guard<std::mutex> lock(io_mu_);
  if (fd_ < 0) return false;
  if (!write_frame(encode_disconnect(next_rid_++, device_id))) return false;
  for (int tries = 0; tries < 32; tries++) {
    std::vector<uint8_t> frame;
    if (!read_frame(frame)) return false;
    size_t i = 0;
    while (i < frame.size()) {
      uint64_t key;
      if (!read_varint(frame.data(), frame.size(), i, key)) break;
      uint32_t field = static_cast<uint32_t>(key >> 3);
      uint32_t wire = static_cast<uint32_t>(key & 7);
      if (field == 3 && wire == 2) return true;
      if (!skip_field(frame.data(), frame.size(), i, wire)) break;
    }
  }
  return false;
}

std::vector<uint8_t> build_adv_payload(const BridgeAdv& adv) {
  if (!adv.raw_adv.empty()) {
    return adv.raw_adv;
  }
  std::vector<uint8_t> ad;
  // Flags: LE General Discoverable + BR/EDR Not Supported
  ad.push_back(0x02);
  ad.push_back(0x01);
  ad.push_back(0x06);
  if (!adv.name.empty()) {
    size_t nlen = adv.name.size();
    if (nlen > 29) nlen = 29;
    // Cap so Flags(3) + name AD stays within 31-byte legacy AD limit.
    const size_t room = (ad.size() < 31) ? (31 - ad.size()) : 0;
    if (room >= 2) {
      if (nlen > room - 2) nlen = room - 2;
      ad.push_back(static_cast<uint8_t>(1 + nlen));
      ad.push_back(0x09);  // Complete Local Name
      ad.insert(ad.end(), adv.name.begin(), adv.name.begin() + static_cast<std::ptrdiff_t>(nlen));
    }
  }
  if (!adv.manufacturer_data.empty()) {
    const size_t room = (ad.size() < 31) ? (31 - ad.size()) : 0;
    if (room >= 2 && adv.manufacturer_data.size() + 1 <= room) {
      ad.push_back(static_cast<uint8_t>(1 + adv.manufacturer_data.size()));
      ad.push_back(0xFF);
      ad.insert(ad.end(), adv.manufacturer_data.begin(), adv.manufacturer_data.end());
    }
  }
  // Include 16-bit service UUIDs when they fit (helps filtered BLE scanners).
  std::vector<uint8_t> uuid16;
  for (const auto& u : adv.service_uuids) {
    // Accept "180f" or full "0000180f-0000-1000-8000-00805f9b34fb"
    std::string hex;
    if (u.size() >= 8 && u[4] == '-') {
      hex = u.substr(4, 4);  // 16-bit from Bluetooth base UUID
    } else if (u.size() == 4) {
      hex = u;
    } else if (u.size() == 36 && u[8] == '-') {
      hex = u.substr(4, 4);
    }
    if (hex.size() != 4) continue;
    unsigned int v = 0;
    if (std::sscanf(hex.c_str(), "%x", &v) != 1) continue;
    uuid16.push_back(static_cast<uint8_t>(v & 0xff));
    uuid16.push_back(static_cast<uint8_t>((v >> 8) & 0xff));
    if (uuid16.size() >= 12) break;  // keep AD short
  }
  if (!uuid16.empty()) {
    const size_t room = (ad.size() < 31) ? (31 - ad.size()) : 0;
    if (room >= 2 + uuid16.size()) {
      ad.push_back(static_cast<uint8_t>(1 + uuid16.size()));
      ad.push_back(0x03);  // Complete List of 16-bit Service UUIDs
      ad.insert(ad.end(), uuid16.begin(), uuid16.end());
    }
  }
  return ad;
}

bool parse_bd_addr(const std::string& s, uint8_t out[6]) {
  unsigned int b[6];
  if (std::sscanf(s.c_str(), "%02x:%02x:%02x:%02x:%02x:%02x", &b[0], &b[1], &b[2], &b[3], &b[4],
                  &b[5]) != 6) {
    return false;
  }
  // HCI uses little-endian address order
  for (int i = 0; i < 6; i++) {
    out[i] = static_cast<uint8_t>(b[5 - i]);
  }
  return true;
}

uint8_t proto_address_type_to_hci(uint8_t proto_address_type) {
  // waydroid_bt.v1.AddressType: PUBLIC=1, RANDOM=2
  // HCI LE Address_Type: Public=0x00, Random=0x01
  if (proto_address_type == kProtoAddrRandom) {
    return kHciAddrRandom;
  }
  // PUBLIC and UNSPECIFIED/default → public device address
  return kHciAddrPublic;
}

}  // namespace waydroid_bt
