#define LOG_TAG "android.hardware.bluetooth@1.0-service.waydroid"

#include "BluetoothHci.h"

#include <log/log.h>

#include <time.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <utility>

namespace android {
namespace hardware {
namespace bluetooth {
namespace V1_0 {
namespace implementation {

BluetoothHci::BluetoothHci() {
  // Deliver HCI events on a dedicated worker. Calling hciEventReceived()
  // synchronously from sendHciCommand() deadlocks the GD Controller start
  // future (same binder thread waits for its own response). A single ordered
  // worker also preserves command-complete order required by HciLayer.
  soft_.set_event_sink([this](const waydroid_bt::Packet& event) {
    enqueueEvent(event);
  });
  soft_.set_scan_enable_hook([this](bool enable) { onScanEnable(enable); });
  soft_.set_le_create_connection_hook_ex(
      [this](const uint8_t peer[6], uint8_t t, uint64_t gen, uint8_t policy) {
        onLeCreateConnection(peer, t, gen, policy);
      });
  soft_.set_disconnect_hook([this](uint16_t handle, uint8_t /*reason*/) {
    // Join notify worker after signaling stop+close, but only erase after the
    // worker can no longer observe the session map entry (shared_ptr keeps IPC).
    std::thread joiner;
    std::shared_ptr<waydroid_bt::BridgeIpc> ipc;
    std::string peer;
    std::string device_id;
    {
      std::lock_guard<std::mutex> lock(att_mu_);
      auto it = att_sessions_.find(handle);
      if (it == att_sessions_.end()) return;
      peer = it->second->peer;
      device_id = it->second->device_id;
      it->second->notify_run.store(false);
      ipc = it->second->ipc;
      if (it->second->notify_thread.joinable()) {
        joiner = std::move(it->second->notify_thread);
      }
      // Drop session entry; worker may still hold shared_ptr<BridgeIpc>.
      att_sessions_.erase(it);
      ALOGI("Soft HCI Disconnect hook close ATT session handle=0x%04x peer=%s", handle,
            peer.c_str());
    }
    if (ipc) {
      if (!device_id.empty()) {
        ipc->disconnect_device(device_id);
      }
      ipc->close();  // unblocks poll under io_mu_
    }
    if (joiner.joinable()) {
      joiner.join();
    }
  });
  event_thread_ = std::thread([this]() { eventWorker(); });
  scan_thread_ = std::thread([this]() { scanWorker(); });
  le_conn_thread_ = std::thread([this]() { leConnectWorker(); });
  keepalive_thread_ = std::thread([this]() { keepaliveWorker(); });
}

BluetoothHci::~BluetoothHci() {
  stop_.store(true);
  scan_want_.store(false);
  q_cv_.notify_all();
  scan_cv_.notify_all();
  le_conn_cv_.notify_all();
  {
    std::lock_guard<std::mutex> lock(att_mu_);
    closeAllAttSessionsLocked(/*inject_hci_disconnect=*/false);
  }
  drainPendingNotifyJoins();
  if (event_thread_.joinable()) {
    event_thread_.join();
  }
  if (scan_thread_.joinable()) {
    scan_thread_.join();
  }
  if (le_conn_thread_.joinable()) {
    le_conn_thread_.join();
  }
  keepalive_cv_.notify_all();
  if (keepalive_thread_.joinable()) {
    keepalive_thread_.join();
  }
}

void BluetoothHci::keepaliveWorker() {
  // One long-lived, ping-only connection to the host bridge for the whole HAL
  // lifetime. Scan and LE connect still use their own short-lived sockets;
  // this one only shows (host side and to the watchdog) that the guest is
  // attached, and reattaches on its own after a bridge restart.
  waydroid_bt::BridgeIpc ipc;
  bool attached = false;
  int failures = 0;
  while (!stop_.load()) {
    if (!ipc.connected()) {
      bool ok = false;
      const char* paths[] = {kBridgeSocket, kBridgeSocketAlt, nullptr};
      for (int i = 0; paths[i] && !ok; i++) {
        if (ipc.connect(paths[i])) {
          ok = ipc.ping("soft-hci-keepalive");
          if (!ok) ipc.close();
        }
      }
      if (ok) {
        ALOGI("Soft HCI keepalive attached to host bridge");
        attached = true;
        failures = 0;
      } else {
        if (attached || failures == 0) {
          ALOGW("Soft HCI keepalive: host bridge not reachable; retrying every 2 s");
        }
        attached = false;
        failures++;
        std::unique_lock<std::mutex> lock(keepalive_mu_);
        keepalive_cv_.wait_for(lock, std::chrono::seconds(2), [this]() { return stop_.load(); });
        continue;
      }
    }
    if (ipc.keepalive_wait(1000) == 0) {
      ALOGW("Soft HCI keepalive: host bridge closed the socket; reattaching");
      attached = false;
    }
  }
  ipc.close();
}

void BluetoothHci::enqueueEvent(waydroid_bt::Packet event) {
  {
    std::lock_guard<std::mutex> lock(q_mu_);
    out_q_.push(OutMsg{OutMsg::kEvent, std::move(event)});
  }
  q_cv_.notify_one();
}

void BluetoothHci::enqueueAcl(waydroid_bt::Packet acl) {
  {
    std::lock_guard<std::mutex> lock(q_mu_);
    out_q_.push(OutMsg{OutMsg::kAcl, std::move(acl)});
  }
  q_cv_.notify_one();
}

uint16_t BluetoothHci::allocConnHandleLocked() {
  // Prefer 0x0040.. and skip handles already in use.
  for (int n = 0; n < 256; n++) {
    const uint16_t h = static_cast<uint16_t>(0x0040 + ((next_conn_handle_ - 0x0040 + n) & 0xff));
    if (att_sessions_.find(h) == att_sessions_.end()) {
      next_conn_handle_ = static_cast<uint16_t>(h + 1);
      if (next_conn_handle_ < 0x0040) next_conn_handle_ = 0x0040;
      return h;
    }
  }
  return 0;  // exhausted
}

BluetoothHci::AttSession* BluetoothHci::findSessionByPeerLocked(const std::string& peer) {
  for (auto& kv : att_sessions_) {
    if (kv.second && kv.second->peer == peer) return kv.second.get();
  }
  return nullptr;
}

BluetoothHci::AttSession* BluetoothHci::findSessionByHandleLocked(uint16_t handle) {
  auto it = att_sessions_.find(handle);
  return it == att_sessions_.end() ? nullptr : it->second.get();
}

uint16_t BluetoothHci::aclHandleOf(const waydroid_bt::Packet& acl) {
  if (acl.size() < 2) return 0;
  return static_cast<uint16_t>(acl[0] | ((static_cast<uint16_t>(acl[1] & 0x0f)) << 8));
}

void BluetoothHci::closeAttSessionLocked(uint16_t handle, bool inject_hci_disconnect) {
  // Caller holds att_mu_. Must NOT call BridgeIpc::close/disconnect while
  // holding att_mu_ (worker: io_mu_ then att_mu_ → ABBA deadlock with
  // att_mu_ then io_mu_). Extract shared_ptr + thread, erase map, queue
  // post-work for drainPendingNotifyJoins() after unlock.
  auto it = att_sessions_.find(handle);
  if (it == att_sessions_.end()) return;
  AttSession* s = it->second.get();
  const bool was_active = s->link.active();
  const std::string peer = s->peer;
  PendingIpcClose pc;
  pc.ipc = s->ipc;
  pc.device_id = s->device_id;
  pc.inject_dc = inject_hci_disconnect && was_active;
  pc.handle = handle;
  pc.peer = peer;
  s->notify_run.store(false);
  if (s->notify_thread.joinable()) {
    pc.joiner = std::move(s->notify_thread);
  }
  att_sessions_.erase(it);
  {
    std::lock_guard<std::mutex> jl(pending_join_mu_);
    pending_closes_.push_back(std::move(pc));
  }
}

void BluetoothHci::closeAllAttSessionsLocked(bool inject_hci_disconnect) {
  std::vector<uint16_t> handles;
  handles.reserve(att_sessions_.size());
  for (const auto& kv : att_sessions_) handles.push_back(kv.first);
  for (uint16_t h : handles) {
    closeAttSessionLocked(h, inject_hci_disconnect);
  }
}

void BluetoothHci::drainPendingNotifyJoins() {
  std::vector<PendingIpcClose> work;
  {
    std::lock_guard<std::mutex> jl(pending_join_mu_);
    work.swap(pending_closes_);
  }
  for (auto& pc : work) {
    if (pc.ipc) {
      if (!pc.device_id.empty()) {
        pc.ipc->disconnect_device(pc.device_id);
      }
      pc.ipc->close();  // under io_mu_; wakes poll
    }
    if (pc.inject_dc) {
      soft_.inject_disconnection_complete(pc.handle, 0x16 /* local host terminated */);
      ALOGI("Soft HCI inject Disconnection Complete handle=0x%04x peer=%s", pc.handle,
            pc.peer.c_str());
    }
    if (pc.joiner.joinable()) {
      pc.joiner.join();
    }
  }
}

void BluetoothHci::attNotifyWorker(uint16_t handle) {
  ALOGI("Soft HCI ATT notify worker started handle=0x%04x", handle);
  while (!stop_.load()) {
    std::shared_ptr<waydroid_bt::BridgeIpc> ipc;
    std::string device_id;
    bool run = false;
    {
      std::lock_guard<std::mutex> lock(att_mu_);
      AttSession* s = findSessionByHandleLocked(handle);
      if (!s) break;
      run = s->notify_run.load();
      // Copy shared_ptr so session erase cannot free BridgeIpc under our feet.
      ipc = s->ipc;
      device_id = s->device_id;
    }
    if (!run) break;
    if (!ipc || !ipc->connected()) {
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
      continue;
    }
    std::string cu;
    std::vector<uint8_t> val;
    // Filter by host device_id so multi-link peers never inject each other's HVNs
    // (host may fan-out GattNotification events to every guest client).
    if (!ipc->poll_gatt_notification(&cu, &val, 200, device_id)) {
      continue;
    }
    ALOGI("Soft HCI ATT host notify handle=0x%04x peer=%s char=%s len=%zu", handle,
          device_id.c_str(), cu.c_str(), val.size());
    std::lock_guard<std::mutex> lock(att_mu_);
    AttSession* s = findSessionByHandleLocked(handle);
    if (!s || !s->link.active()) continue;
    s->link.notify_value(cu, val, [this](const waydroid_bt::Packet& a) { enqueueAcl(a); });
  }
  ALOGI("Soft HCI ATT notify worker stopped handle=0x%04x", handle);
}

void BluetoothHci::onScanEnable(bool enable) {
  ALOGI("Soft HCI LE scan enable=%d (bridge)", enable ? 1 : 0);
  scan_want_.store(enable);
  if (enable) {
    // Hold host discovery long enough for app-level scans (Flowlog = 8s).
    // Fluoride/GD often pulses LE_Set_Scan_Enable off during reconfig even
    // while apps still have an active scanner — without a hold window the
    // host session dies in <1s and Flowlog reports "sensors not found".
    constexpr auto kScanHold = std::chrono::seconds(12);
    std::lock_guard<std::mutex> lock(scan_mu_);
    const auto until = std::chrono::steady_clock::now() + kScanHold;
    if (until > scan_hold_until_) {
      scan_hold_until_ = until;
    }
  }
  scan_cv_.notify_all();
}

void BluetoothHci::scanWorker() {
  // Effective "want scan" = HCI enable bit OR still inside hold window after
  // the last enable. Debounce alone was not enough: host sessions still died
  // ~0.6s after StartLeScan while Flowlog's 8s scan collected 0 results.
  auto scan_active_locked = [this]() -> bool {
    // Caller must hold scan_mu_ when checking hold deadline.
    return scan_want_.load() || std::chrono::steady_clock::now() < scan_hold_until_;
  };
  auto scan_active = [this, &scan_active_locked]() -> bool {
    if (scan_want_.load()) {
      return true;
    }
    std::lock_guard<std::mutex> lock(scan_mu_);
    return scan_active_locked();
  };

  waydroid_bt::BridgeIpc ipc;
  uint32_t session = 0;
  while (!stop_.load()) {
    if (!scan_active()) {
      if (session != 0 && ipc.connected()) {
        ALOGI("Soft HCI bridge StopLeScan session=%u", session);
        ipc.stop_le_scan(session);
        session = 0;
      }
      if (ipc.connected()) {
        ipc.close();
      }
      scan_running_.store(false);
      std::unique_lock<std::mutex> lock(scan_mu_);
      scan_cv_.wait(lock, [this, &scan_active_locked]() {
        return stop_.load() || scan_active_locked();
      });
      continue;
    }

    if (!ipc.connected()) {
      const char* paths[] = {kBridgeSocket, kBridgeSocketAlt, nullptr};
      bool ok = false;
      for (int i = 0; paths[i]; i++) {
        if (ipc.connect(paths[i])) {
          ALOGI("Soft HCI bridge connected to %s", paths[i]);
          ok = true;
          break;
        }
      }
      if (!ok) {
        ALOGE("Soft HCI bridge connect failed; retrying");
        std::unique_lock<std::mutex> lock(scan_mu_);
        scan_cv_.wait_for(lock, std::chrono::seconds(2),
                          [this]() { return stop_.load() || !scan_want_.load(); });
        continue;
      }
    }

    if (session == 0) {
      session = ipc.start_le_scan(true);
      if (session == 0) {
        ALOGE("Soft HCI bridge StartLeScan failed");
        ipc.close();
        std::unique_lock<std::mutex> lock(scan_mu_);
        scan_cv_.wait_for(lock, std::chrono::seconds(1),
                          [this]() { return stop_.load() || !scan_want_.load(); });
        continue;
      }
      ALOGI("Soft HCI bridge StartLeScan session=%u (hold=12s for app scanners)", session);
      scan_running_.store(true);
    }

    waydroid_bt::BridgeAdv adv;
    if (!ipc.poll_adv(adv, 400)) {
      // Drop dead IPC so the next loop reconnects (host restart / reset-by-peer).
      if (!ipc.connected()) {
        ALOGW("Soft HCI bridge IPC lost during scan; will reconnect");
        session = 0;
        scan_running_.store(false);
      }
      continue;
    }
    uint8_t addr[6] = {};
    if (!waydroid_bt::parse_bd_addr(adv.address, addr)) {
      ALOGW("Soft HCI bridge bad address '%s'", adv.address.c_str());
      continue;
    }
    auto payload = waydroid_bt::build_adv_payload(adv);
    uint8_t evt_type = adv.connectable ? 0x00 : 0x03;  // ADV_IND vs NONCONN_IND
    // Proto AddressType is 1=PUBLIC/2=RANDOM; HCI LE Address_Type is 0/1.
    const uint8_t hci_addr_type = waydroid_bt::proto_address_type_to_hci(adv.address_type);
    // LE advertising only by default — EIR made Fluoride classic-pair BLE lamps and crash.
    soft_.inject_bridged_device(addr, hci_addr_type, adv.rssi, payload, adv.name, evt_type,
                                /*inject_eir=*/false);
    ALOGI("Soft HCI bridge DEVICE %s proto_at=%u hci_at=%u rssi=%d name='%s' dlen=%zu inquiry=%d eir=0",
          adv.address.c_str(), static_cast<unsigned>(adv.address_type),
          static_cast<unsigned>(hci_addr_type), static_cast<int>(adv.rssi), adv.name.c_str(),
          payload.size(), soft_.inquiry_active() ? 1 : 0);
  }

  if (session != 0 && ipc.connected()) {
    ipc.stop_le_scan(session);
  }
  ipc.close();
  scan_running_.store(false);
}

void BluetoothHci::eventWorker() {
  while (true) {
    OutMsg msg;
    {
      std::unique_lock<std::mutex> lock(q_mu_);
      q_cv_.wait(lock, [this]() { return stop_.load() || !out_q_.empty(); });
      if (stop_.load() && out_q_.empty()) {
        return;
      }
      msg = std::move(out_q_.front());
      out_q_.pop();
    }

    sp<IBluetoothHciCallbacks> cb;
    {
      std::lock_guard<std::mutex> lock(mu_);
      cb = callbacks_;
    }
    if (cb == nullptr) {
      continue;
    }
    hidl_vec<uint8_t> vec;
    vec.resize(msg.data.size());
    if (!msg.data.empty()) {
      memcpy(vec.data(), msg.data.data(), msg.data.size());
    }
    if (msg.type == OutMsg::kEvent) {
      auto st = cb->hciEventReceived(vec);
      if (!st.isOk()) {
        ALOGE("hciEventReceived failed");
      }
    } else {
      auto st = cb->aclDataReceived(vec);
      if (!st.isOk()) {
        ALOGE("aclDataReceived failed");
      }
    }
  }
}

Return<void> BluetoothHci::initialize(const sp<IBluetoothHciCallbacks>& callback) {
  ALOGI("Soft HCI initialize()");
  {
    std::lock_guard<std::mutex> lock(mu_);
    callbacks_ = callback;
  }
  soft_.reset();
  if (callback != nullptr) {
    auto st = callback->initializationComplete(Status::SUCCESS);
    if (!st.isOk()) {
      ALOGE("initializationComplete failed");
    } else {
      ALOGI("Soft HCI initializationComplete(SUCCESS)");
    }
  }
  return Void();
}

Return<void> BluetoothHci::sendHciCommand(const hidl_vec<uint8_t>& command) {
  waydroid_bt::Packet cmd(command.begin(), command.end());
  uint16_t opc = waydroid_bt::SoftHci::opcode_of(cmd);
  ALOGI("Soft HCI cmd opcode=0x%04x len=%zu", opc, cmd.size());
  soft_.handle_command(cmd);
  if (opc == 0x200E /* LE Create Connection Cancel */ || opc == 0x0C03 /* Reset */) {
    // Stop a pending host connect attempt now; the stack already got its
    // Connection Complete (0x02) from Soft HCI.
    std::shared_ptr<waydroid_bt::BridgeIpc> inflight;
    {
      std::lock_guard<std::mutex> lock(le_conn_mu_);
      inflight = le_inflight_ipc_;
    }
    if (inflight) inflight->shutdown_io();
    le_conn_cv_.notify_all();
  }
  return Void();
}

void BluetoothHci::onLeCreateConnection(const uint8_t peer_addr_le[6], uint8_t peer_addr_type,
                                        uint64_t gen, uint8_t filter_policy) {
  {
    std::lock_guard<std::mutex> lock(le_conn_mu_);
    PendingLeConn p;
    std::memcpy(p.peer, peer_addr_le, 6);
    p.peer_type = peer_addr_type;
    p.gen = gen;
    p.filter_policy = filter_policy;
    le_conn_queue_.push(p);
  }
  le_conn_cv_.notify_one();
}

// Suspend detection: CLOCK_BOOTTIME advances during s2idle, CLOCK_MONOTONIC
// does not. Returns ms of suspend since the previous call (first call: 0).
static int64_t suspendGapMs() {
  static std::mutex mu;
  static int64_t last_delta = -1;
  timespec b{}, m{};
  clock_gettime(CLOCK_BOOTTIME, &b);
  clock_gettime(CLOCK_MONOTONIC, &m);
  const int64_t delta = (static_cast<int64_t>(b.tv_sec) - m.tv_sec) * 1000 +
                        (static_cast<int64_t>(b.tv_nsec) - m.tv_nsec) / 1000000;
  std::lock_guard<std::mutex> lock(mu);
  const int64_t gap = last_delta < 0 ? 0 : delta - last_delta;
  last_delta = delta;
  return gap > 0 ? gap : 0;
}

void BluetoothHci::leConnectWorker() {
  while (!stop_.load()) {
    PendingLeConn p;
    {
      std::unique_lock<std::mutex> lock(le_conn_mu_);
      le_conn_cv_.wait(lock, [this]() { return stop_.load() || !le_conn_queue_.empty(); });
      if (stop_.load() && le_conn_queue_.empty()) {
        return;
      }
      if (le_conn_queue_.empty()) {
        continue;
      }
      p = le_conn_queue_.front();
      le_conn_queue_.pop();
    }
    if (stop_.load()) {
      return;
    }
    if (!soft_.le_create_pending_gen(p.gen)) {
      ALOGI("Soft HCI LE Create Connection gen=%llu already cancelled — skip",
            static_cast<unsigned long long>(p.gen));
      continue;
    }

    // Keep the connection pending and retry the host link until it is up or
    // the stack cancels, like a real controller does for an absent peer. A
    // missing car is therefore never a stack-visible failure; the Tesla app
    // sees the usual timeout/cancel from Android itself and keeps retrying.
    const auto started = std::chrono::steady_clock::now();
    suspendGapMs();  // reset baseline
    int attempt = 0;
    bool first = true;
    int passive_early = 0;  // consecutive passive waits that ended early
    size_t rr = 0;  // round-robin over the accept list for background connects
    while (!stop_.load() && soft_.le_create_pending_gen(p.gen)) {
      uint8_t target[6];
      uint8_t target_type = p.peer_type;
      std::memcpy(target, p.peer, 6);
      size_t list_size = 0;
      if (p.filter_policy == 0x01) {
        auto list = soft_.accept_list_snapshot();
        list_size = list.size();
        if (!list.empty()) {
          // Most recent entry first, then the others in turn.
          const auto& e = list[list.size() - 1 - (rr++ % list.size())];
          std::memcpy(target, e.addr_le, 6);
          target_type = e.addr_type;
        }
      }
      attempt++;
      // Background connect, peer absent after the first quick try: let the
      // host kernel wait passively (LE auto-connect, low-duty passive scan)
      // instead of polling with active scans. Still pending for the stack.
      const bool passive =
          waydroid_bt::SoftHci::use_passive_wait(p.filter_policy, attempt, passiveUnsupportedNow());
      const uint32_t wait_ms = passive ? waydroid_bt::SoftHci::passive_wait_ms(list_size) : 0;
      const auto attempt_started = std::chrono::steady_clock::now();
      int r = attemptHostLeConnect(target, target_type, p.gen, first, wait_ms);
      first = false;
      if (r == kAttemptUnsupported) {
        const int64_t now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                                   std::chrono::steady_clock::now().time_since_epoch())
                                   .count();
        passive_unsupported_until_ms_.store(now_ms + kPassiveUnsupportedRetryMs);
        ALOGW("Soft HCI LE pending connect gen=%llu: host cannot wait passively — "
              "active retries for %lld min",
              static_cast<unsigned long long>(p.gen),
              static_cast<long long>(kPassiveUnsupportedRetryMs / 60000));
        r = kAttemptFailed;
      }
      if (r != kAttemptFailed) break;
      if (!soft_.le_create_pending_gen(p.gen)) break;

      const auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                                  std::chrono::steady_clock::now() - started)
                                  .count();
      if (p.filter_policy == 0x00 && elapsed_ms >= waydroid_bt::SoftHci::kDirectConnectMaxMs) {
        // Safety net only: GD cancels direct connects itself after 30 s.
        if (soft_.inject_le_connection_complete_if(p.gen, 0x3E, 0x0000, 0x00, p.peer_type,
                                                   p.peer)) {
          ALOGI("Soft HCI LE direct connect gen=%llu no cancel after %lld ms — status=0x3E",
                static_cast<unsigned long long>(p.gen), static_cast<long long>(elapsed_ms));
        }
        break;
      }
      int delay_ms = 0;
      if (passive) {
        const int64_t waited_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                                      std::chrono::steady_clock::now() - attempt_started)
                                      .count();
        passive_early = (waited_ms + 2000 >= static_cast<int64_t>(wait_ms)) ? 0 : passive_early + 1;
        delay_ms = waydroid_bt::SoftHci::passive_rearm_delay_ms(waited_ms, wait_ms, passive_early);
        ALOGI("Soft HCI LE pending connect gen=%llu: passive wait ended after %lld s without "
              "link; re-arm in %d s (still pending, nothing reported to the stack)",
              static_cast<unsigned long long>(p.gen), static_cast<long long>(waited_ms / 1000),
              delay_ms / 1000);
        if (delay_ms == 0) continue;
      } else {
        delay_ms = waydroid_bt::SoftHci::pending_connect_retry_delay_ms(attempt);
        ALOGI("Soft HCI LE pending connect gen=%llu policy=%u attempt=%d: host link not up; "
              "retry in %d s (still pending, nothing reported to the stack)",
              static_cast<unsigned long long>(p.gen), static_cast<unsigned>(p.filter_policy),
              attempt, delay_ms / 1000);
      }
      // Wait in short slices so a resume from suspend (peer may now be in
      // range) or a cancel is noticed quickly.
      auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(delay_ms);
      while (!stop_.load() && soft_.le_create_pending_gen(p.gen)) {
        const auto now = std::chrono::steady_clock::now();
        if (now >= until) break;
        const int64_t gap = suspendGapMs();
        if (gap > 5000) {
          ALOGI("Soft HCI LE pending connect gen=%llu: resumed after %lld s suspend — retry now",
                static_cast<unsigned long long>(p.gen), static_cast<long long>(gap / 1000));
          attempt = 0;  // fast retries again
          break;
        }
        std::unique_lock<std::mutex> lock(le_conn_mu_);
        le_conn_cv_.wait_for(lock, std::min(std::chrono::milliseconds(2000),
                                            std::chrono::duration_cast<std::chrono::milliseconds>(
                                                until - now)));
        if (!le_conn_queue_.empty()) break;  // newer request (old one is stale then)
      }
    }
  }
}

bool BluetoothHci::passiveUnsupportedNow() const {
  const int64_t until = passive_unsupported_until_ms_.load();
  if (until == 0) return false;
  const int64_t now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                             std::chrono::steady_clock::now().time_since_epoch())
                             .count();
  return now_ms < until;
}

int BluetoothHci::attemptHostLeConnect(const uint8_t peer[6], uint8_t peer_type, uint64_t gen,
                                       bool first_attempt, uint32_t passive_wait_ms) {
  // Format AA:BB:... from HCI LE byte order (little-endian of colon string).
  char addr_str[18];
  std::snprintf(addr_str, sizeof(addr_str), "%02X:%02X:%02X:%02X:%02X:%02X", peer[5], peer[4],
                peer[3], peer[2], peer[1], peer[0]);
  ALOGI("Soft HCI LE Create Connection peer=%s type=%u — host bridge + ATT (multi-link)",
        addr_str, static_cast<unsigned>(peer_type));

  // Already bridged to this peer: re-emit success — keep other links intact.
  {
    std::lock_guard<std::mutex> lock(att_mu_);
    if (AttSession* existing = findSessionByPeerLocked(addr_str)) {
      ALOGI("Soft HCI LE already connected to %s handle=0x%04x — re-inject CC", addr_str,
            existing->handle);
      soft_.inject_le_connection_complete_if(gen, 0x00, existing->handle, 0x00, peer_type, peer);
      return kAttemptDone;
    }
    if (att_sessions_.size() >= kMaxAttSessions) {
      ALOGW("Soft HCI LE max concurrent links (%zu) — reject %s", kMaxAttSessions, addr_str);
      soft_.inject_le_connection_complete_if(gen, 0x0D /* Connection Rejected Limited Resources */,
                                          0x0000, 0x00, peer_type, peer);
      return kAttemptDone;
    }
  }

  // Pause scan briefly so BlueZ can connect (first attempt only, so a long
  // pending background connect never keeps killing app scans); do NOT tear
  // down existing ATT.
  if (first_attempt) {
    {
      std::lock_guard<std::mutex> lock(scan_mu_);
      scan_hold_until_ = {};
      scan_want_.store(false);
    }
    scan_cv_.notify_all();
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
  }
  if (!soft_.le_create_pending_gen(gen)) return kAttemptStale;

  auto ipc = std::make_shared<waydroid_bt::BridgeIpc>();
  bool ok = false;
  std::string device_id;
  std::string summary;
  std::vector<std::pair<std::string, std::vector<waydroid_bt::BridgeIpc::GattChar>>> services;
  uint32_t host_error = 0;
  const char* paths[] = {kBridgeSocket, kBridgeSocketAlt, nullptr};
  for (int i = 0; paths[i]; i++) {
    if (ipc->connect(paths[i])) {
      ALOGI("Soft HCI bridge connect_le_open via %s peer=%s gen=%llu", paths[i], addr_str,
            static_cast<unsigned long long>(gen));
      {
        std::lock_guard<std::mutex> lock(le_conn_mu_);
        le_inflight_ipc_ = ipc;
      }
      // Re-check after publishing: a Cancel that raced in before we stored
      // the pointer could not shut this socket down.
      if (soft_.le_create_pending_gen(gen)) {
        if (passive_wait_ms > 0) {
          // Passive: host kernel LE auto-connect, no active scan; answers when
          // the link is up or after passive_wait_ms (peer not in range).
          ok = ipc->connect_le_open(addr_str, passive_wait_ms, &device_id, &services, &summary,
                                    /*wait_passive=*/true,
                                    peer_type == waydroid_bt::kHciAddrRandom
                                        ? waydroid_bt::kProtoAddrRandom
                                        : waydroid_bt::kProtoAddrPublic,
                                    &host_error);
        } else {
          // 25 s total on the host (scan + connect, one deadline): answers
          // before GD's 30 s direct-connect timeout.
          ok = ipc->connect_le_open(addr_str, kHostConnectAttemptMs, &device_id, &services,
                                    &summary);
        }
      }
      {
        std::lock_guard<std::mutex> lock(le_conn_mu_);
        le_inflight_ipc_.reset();
      }
      break;
    }
  }
  if (!ok) {
    if (passive_wait_ms > 0 && host_error == waydroid_bt::kErrUnsupported) {
      return kAttemptUnsupported;
    }
    if (passive_wait_ms > 0 && host_error == waydroid_bt::kErrTimeout) {
      // Normal while the car is away; the worker re-arms.
      return kAttemptFailed;
    }
    // Car / peer absent or link setup failed: NOT reported to the stack. The
    // LE Create Connection stays pending (real-controller semantics) and the
    // worker retries; the stack decides when to give up (Cancel).
    ALOGW("Soft HCI bridge LE connect/GATT failed peer=%s summary=%s (stays pending)", addr_str,
          summary.empty() ? "none" : summary.c_str());
    // Closing the socket (ipc goes out of scope) makes the host drop any
    // half-open link this attempt still owned.
    return kAttemptFailed;
  }

  ALOGI("Soft HCI bridge %s", summary.c_str());
  uint16_t handle = 0;
  {
    std::lock_guard<std::mutex> lock(att_mu_);
    // Race: peer might have been connected by another path.
    if (AttSession* existing = findSessionByPeerLocked(addr_str)) {
      ALOGI("Soft HCI LE peer %s connected during open — drop duplicate host link", addr_str);
      ipc->disconnect_device(device_id);
      ipc->close();
      soft_.inject_le_connection_complete_if(gen, 0x00, existing->handle, 0x00, peer_type, peer);
      return kAttemptDone;
    }
    handle = allocConnHandleLocked();
    if (handle == 0) {
      ipc->disconnect_device(device_id);
      ipc->close();
      soft_.inject_le_connection_complete_if(gen, 0x0D, 0x0000, 0x00, peer_type, peer);
      return kAttemptDone;
    }
    auto sess = std::make_unique<AttSession>();
    sess->handle = handle;
    sess->peer = addr_str;
    sess->device_id = device_id;
    sess->ipc = std::move(ipc);
    sess->link.set_conn_handle(handle);
    sess->link.set_peer(addr_str, peer_type);

    waydroid_bt::BridgeIpc* ipc_ptr = sess->ipc.get();
    const std::string dev = device_id;
    waydroid_bt::AttHostOps ops;
    ops.read_char = [ipc_ptr, dev](const std::string& cu, const std::string& su,
                                   std::vector<uint8_t>* v) {
      return ipc_ptr && ipc_ptr->gatt_read_uuid(dev, cu, su, v);
    };
    ops.write_char = [ipc_ptr, dev](const std::string& cu, const std::string& su,
                                    const std::vector<uint8_t>& v, bool wr) {
      return ipc_ptr && ipc_ptr->gatt_write_uuid(dev, cu, su, v, wr);
    };
    ops.set_notify = [ipc_ptr, dev](const std::string& cu, const std::string& su, bool en) {
      const bool sn_ok = ipc_ptr && ipc_ptr->gatt_set_notify_uuid(dev, cu, su, en);
      ALOGI("Soft HCI set_notify peer_dev=%s char=%s en=%d ok=%d", dev.c_str(), cu.c_str(),
            en ? 1 : 0, sn_ok ? 1 : 0);
      return sn_ok;
    };
    sess->link.set_host_ops(std::move(ops));

    using HostTree =
        std::vector<std::pair<std::string, std::vector<waydroid_bt::BridgeIpc::GattChar>>>;
    auto has_uuid = [](const HostTree& svcs, const char* needle) {
      for (const auto& s : svcs) {
        std::string u = s.first;
        for (char& c : u) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        if (u.find(needle) != std::string::npos) return true;
        for (const auto& c : s.second) {
          std::string cu = c.uuid;
          for (char& ch : cu) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
          if (cu.find(needle) != std::string::npos) return true;
        }
      }
      return false;
    };
    // Only complete a partial Pressensor tree when host already reported
    // Pressensor UUIDs. Never invent Pressensor/Battery services on unrelated
    // peers (Tesla, etc.) — that polluted Soft ATT and confused apps.
    const bool looks_decent =
        has_uuid(services, "fff0") || has_uuid(services, "fff4") || has_uuid(services, "36f5");
    const bool looks_pressensor = has_uuid(services, "873ae82");
    if (looks_pressensor) {
      if (!has_uuid(services, "873ae82a")) {
        ALOGI("Soft HCI ATT complete Pressensor service 873ae82a (host partial)");
        services.push_back(
            {"873ae82a-4c5a-4342-b539-9d900bf7ebd0",
             {{"873ae82b-4c5a-4342-b539-9d900bf7ebd0", 0x12},
              {"873ae82c-4c5a-4342-b539-9d900bf7ebd0", 0x0C},
              {"873ae832-4c5a-4342-b539-9d900bf7ebd0", 0x0C}}});
      }
      if (!has_uuid(services, "873ae828")) {
        services.push_back(
            {"873ae828-4c5a-4342-b539-9d900bf7ebd0",
             {{"873ae829-4c5a-4342-b539-9d900bf7ebd0", 0x12}}});
      }
      if (!has_uuid(services, "180f") && !has_uuid(services, "2a19")) {
        services.push_back(
            {"0000180f-0000-1000-8000-00805f9b34fb",
             {{"00002a19-0000-1000-8000-00805f9b34fb", 0x12}}});
      }
    } else if (looks_decent) {
      ALOGI("Soft HCI ATT Decent/fff0 tree — no Pressensor inject");
    } else {
      ALOGI("Soft HCI ATT host tree only (no synthetic Pressensor) peer=%s", addr_str);
    }
    ALOGI("Soft HCI ATT build peer=%s looks_decent=%d looks_pressensor=%d services=%zu "
          "active_links=%zu",
          addr_str, looks_decent ? 1 : 0, looks_pressensor ? 1 : 0, services.size(),
          att_sessions_.size() + 1);

    std::vector<std::pair<std::string, std::vector<waydroid_bt::SoftAttLink::CharSpec>>> att_svcs;
    att_svcs.reserve(services.size());
    for (const auto& s : services) {
      std::vector<waydroid_bt::SoftAttLink::CharSpec> chars;
      chars.reserve(s.second.size());
      for (const auto& c : s.second) {
        chars.push_back({c.uuid, c.properties});
        ALOGI("Soft HCI ATT char peer=%s svc=%s uuid=%s props=0x%02x", addr_str, s.first.c_str(),
              c.uuid.c_str(), static_cast<unsigned>(c.properties));
      }
      att_svcs.emplace_back(s.first, std::move(chars));
    }
    sess->link.build_from_uuids(att_svcs);
    if (!soft_.inject_le_connection_complete_if(gen, 0x00, handle, 0x00, peer_type, peer)) {
      // Stack cancelled while the host was connecting: drop the host link.
      ALOGI("Soft HCI LE connect done but attempt gen=%llu was cancelled — drop host link peer=%s",
            static_cast<unsigned long long>(gen), addr_str);
      sess->ipc->disconnect_device(device_id);
      sess->ipc->close();
      return kAttemptStale;
    }
    ALOGI("Soft HCI LE Connection Complete status=0x00 handle=0x%04x peer=%s multi-link OK",
          handle, addr_str);

    sess->notify_run.store(true);
    const uint16_t h = handle;
    sess->notify_thread = std::thread([this, h]() { attNotifyWorker(h); });
    att_sessions_[handle] = std::move(sess);
  }
  return kAttemptDone;
}

Return<void> BluetoothHci::sendAclData(const hidl_vec<uint8_t>& data) {
  waydroid_bt::Packet acl(data.begin(), data.end());
  const uint16_t handle = aclHandleOf(acl);
  std::lock_guard<std::mutex> lock(att_mu_);
  AttSession* s = findSessionByHandleLocked(handle);
  if (!s || !s->link.active()) {
    // Fallback: single session may still match if handle mask oddities.
    if (att_sessions_.size() == 1) {
      s = att_sessions_.begin()->second.get();
    } else {
      return Void();
    }
  }
  if (!s || !s->link.active()) {
    return Void();
  }
  s->link.on_acl_from_stack(
      acl,
      [this](const waydroid_bt::Packet& a) { enqueueAcl(a); },
      [this](const waydroid_bt::Packet& e) { enqueueEvent(e); });
  return Void();
}

Return<void> BluetoothHci::sendScoData(const hidl_vec<uint8_t>& /*data*/) {
  return Void();
}

Return<void> BluetoothHci::close() {
  ALOGI("Soft HCI close()");
  scan_want_.store(false);
  {
    std::lock_guard<std::mutex> lock(scan_mu_);
    scan_hold_until_ = {};
  }
  scan_cv_.notify_all();
  {
    std::lock_guard<std::mutex> lock(att_mu_);
    closeAllAttSessionsLocked(/*inject_hci_disconnect=*/true);
  }
  drainPendingNotifyJoins();
  std::lock_guard<std::mutex> lock(mu_);
  callbacks_ = nullptr;
  return Void();
}

}  // namespace implementation
}  // namespace V1_0
}  // namespace bluetooth
}  // namespace hardware
}  // namespace android
