// Soft (virtual) HCI controller — no real radio / no BlueZ HCI ownership.
// Synthesizes command-complete events so Fluoride can leave BLE_TURNING_ON.
// LE scan + classic Inquiry are hooked so the HAL can bridge discovery to host BlueZ
// (Settings "Pair new device" uses Inquiry and/or LE scan).
//
// LE Create Connection must never leave the stack half-open: always follow
// Command Status with LE Connection Complete (success or failure).
#pragma once

#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

namespace waydroid_bt {

using Packet = std::vector<uint8_t>;
using EventSink = std::function<void(const Packet&)>;
// Called when host-side discovery should start/stop (LE scan and/or Inquiry).
using ScanEnableHook = std::function<void(bool enable)>;
// LE Create Connection: peer address (HCI LE byte order), peer type (0=public,1=random).
// Caller must invoke inject_le_connection_complete when host path finishes.
using LeCreateConnectionHook =
    std::function<void(const uint8_t peer_addr_le[6], uint8_t peer_addr_type)>;
// Same, with the controller-side "attempt" generation and Initiator_Filter_Policy
// (0x00 = direct to Peer_Address, 0x01 = background via Filter Accept List).
// Complete with inject_le_connection_complete_if(gen, ...): it is a no-op once the
// stack cancelled (LE Create Connection Cancel / Reset) or started a newer attempt.
using LeCreateConnectionHookEx = std::function<void(
    const uint8_t peer_addr_le[6], uint8_t peer_addr_type, uint64_t gen, uint8_t filter_policy)>;
// HCI Disconnect for a Soft ATT handle — close host bridge for that link only.
using DisconnectHook = std::function<void(uint16_t handle, uint8_t reason)>;

// Minimal BT controller: address is fixed (guest identity separate from host).
class SoftHci {
 public:
  explicit SoftHci(Packet bd_addr = {0x10, 0xCE, 0xD0, 0x6B, 0xCA, 0x10});

  void set_event_sink(EventSink sink);
  void set_scan_enable_hook(ScanEnableHook hook);
  void set_le_create_connection_hook(LeCreateConnectionHook hook);
  // Preferred over the plain hook when set (keeps the connection pending like a
  // real controller: no failure is reported for an absent peer until cancel).
  void set_le_create_connection_hook_ex(LeCreateConnectionHookEx hook);
  void set_disconnect_hook(DisconnectHook hook);
  void reset();
  void handle_command(const Packet& cmd);

  // Inject a real advertisement as HCI LE Meta / Advertising Report event.
  void inject_le_advertising_report(const uint8_t addr_le[6], uint8_t addr_type, int8_t rssi,
                                    const Packet& adv_data, uint8_t event_type = 0x00);

  // Inject Extended Inquiry Result (Settings classic discovery UI).
  // Prefer LE-only inject for BLE peripherals — EIR makes Fluoride try classic pair.
  void inject_extended_inquiry_result(const uint8_t addr_le[6], int8_t rssi, const std::string& name);

  // LE advertising report; optional EIR (default false — safer for Hue-class BLE).
  void inject_bridged_device(const uint8_t addr_le[6], uint8_t addr_type, int8_t rssi,
                            const Packet& adv_data, const std::string& name,
                            uint8_t event_type = 0x00, bool inject_eir = false);

  // Complete a pending LE Create Connection (LE Meta Connection Complete).
  // Clears le_create_pending. status 0 = success; non-zero = stack-safe fail.
  void inject_le_connection_complete(uint8_t status, uint16_t handle, uint8_t role,
                                     uint8_t peer_addr_type, const uint8_t peer_addr_le[6]);

  // HCI Disconnection Complete (0x05) — must be sent when Soft ATT tears down a
  // live link, otherwise Fluoride still thinks the handle is open and the next
  // LE Create Connection surfaces as Android GATT 133.
  void inject_disconnection_complete(uint16_t handle, uint8_t reason = 0x16);

  // Complete LE Create Connection attempt `gen` only if it is still the pending
  // one. Returns false (emits nothing) after cancel / reset / newer attempt.
  bool inject_le_connection_complete_if(uint64_t gen, uint8_t status, uint16_t handle,
                                        uint8_t role, uint8_t peer_addr_type,
                                        const uint8_t peer_addr_le[6]);

  bool inquiry_active() const;
  bool le_create_pending() const;
  // Generation of the current/last LE Create Connection; bumped by every Create,
  // Cancel and Reset.
  uint64_t le_create_generation() const;
  // True while attempt `gen` is still pending (not completed / cancelled).
  bool le_create_pending_gen(uint64_t gen) const;
  struct AcceptListPeer {
    uint8_t addr_type = 0;
    uint8_t addr_le[6] = {};
  };
  // Copy of the Filter Accept List (background connect targets), most recent last.
  std::vector<AcceptListPeer> accept_list_snapshot() const;

  // Pure helpers (unit-tested):
  // Pause before host connect retry `attempt` (1-based) of a pending LE Create
  // Connection. Short at first (car just walked up to / stack direct connect),
  // then a battery-friendly steady state for a long background connect while
  // the peer is away: 2, 5, 10, 20, 30, 60, then 90 s.
  static int pending_connect_retry_delay_ms(int attempt);
  // Background connect (policy 0x01) for an absent peer: after the first
  // quick active attempt, hand the wait to the host kernel's passive LE
  // auto-connect (ConnectLe wait_passive) instead of active-scan polling,
  // unless the host said it cannot (passive_unsupported).
  static bool use_passive_wait(uint8_t filter_policy, int attempt, bool passive_unsupported);
  // Length of one passive wait. One peer: long (10 min, re-armed at once).
  // Several accept-list peers: 60 s each so the round-robin keeps turning.
  static uint32_t passive_wait_ms(size_t accept_list_size);
  // Pause before re-arming after a passive wait ended without a link. 0 when
  // the wait ran its course (peer simply absent); backoff when it ended early
  // (bridge restart / error), early_failures counting consecutive early ends.
  static int passive_rearm_delay_ms(int64_t waited_ms, uint32_t wait_ms, int early_failures);
  static constexpr uint32_t kPassiveWaitLongMs = 600000;
  static constexpr uint32_t kPassiveWaitShortMs = 60000;
  // Direct connects (policy 0x00) give up with 0x3E after this long without a
  // cancel from the stack (safety net; GD normally cancels after 30 s).
  static constexpr int kDirectConnectMaxMs = 60000;
  static Packet make_command_complete(uint16_t opcode, const Packet& return_params);
  static Packet make_command_status(uint8_t status, uint16_t opcode);
  static uint16_t opcode_of(const Packet& cmd);
  static Packet make_le_advertising_report(const uint8_t addr_le[6], uint8_t addr_type, int8_t rssi,
                                           const Packet& adv_data, uint8_t event_type = 0x00);
  static Packet make_extended_inquiry_result(const uint8_t addr_le[6], int8_t rssi,
                                             const std::string& name);
  static Packet make_inquiry_complete(uint8_t status = 0x00);
  // LE Meta subevent 0x01 Connection Complete (Core Spec Vol 4 Part E).
  static Packet make_le_connection_complete(uint8_t status, uint16_t handle, uint8_t role,
                                            uint8_t peer_addr_type, const uint8_t peer_addr_le[6]);
  // Event 0x05 Disconnection Complete.
  static Packet make_disconnection_complete(uint16_t handle, uint8_t reason, uint8_t status = 0x00);
  // Parse peer from LE Create Connection command body (params after opcode+plen).
  // When Initiator_Filter_Policy==0x01, peer fields in the command are ignored/zero;
  // caller should fall back to the filter accept list (see resolve_le_create_peer).
  static bool parse_le_create_connection_peer(const uint8_t* params, size_t plen,
                                              uint8_t peer_addr_le[6], uint8_t* peer_addr_type,
                                              uint8_t* filter_policy_out = nullptr);

 private:
  void emit(const Packet& event);
  void notify_scan(bool enable);
  // Resolve peer for LE Create Connection: command peer if policy 0x00 and non-zero,
  // else most recently added filter-accept-list entry.
  bool resolve_le_create_peer(const uint8_t* params, size_t plen, uint8_t peer_addr_le[6],
                              uint8_t* peer_addr_type);
  Packet bd_addr_;
  EventSink sink_;
  ScanEnableHook scan_hook_;
  LeCreateConnectionHook le_connect_hook_;
  LeCreateConnectionHookEx le_connect_hook_ex_;
  uint64_t le_create_gen_ = 0;
  DisconnectHook disconnect_hook_;
  mutable std::mutex mu_;
  bool open_ = false;
  bool le_scan_active_ = false;
  bool inquiry_active_ = false;
  bool le_create_pending_ = false;
  uint8_t pending_peer_addr_[6] = {};
  uint8_t pending_peer_type_ = 0;
  // Filter Accept List (HCI LE White List). GD often does Add Device then Create
  // Connection with Initiator_Filter_Policy=0x01 (peer address zeroed in command).
  static constexpr size_t kAcceptListMax = 16;
  struct AcceptListEntry {
    bool in_use = false;
    uint8_t addr_type = 0;
    uint8_t addr_le[6] = {};
  };
  AcceptListEntry accept_list_[kAcceptListMax] = {};
  // Last successfully added entry (fast path for single-device connect).
  bool accept_list_last_valid_ = false;
  uint8_t accept_list_last_type_ = 0;
  uint8_t accept_list_last_addr_[6] = {};
};

}  // namespace waydroid_bt
