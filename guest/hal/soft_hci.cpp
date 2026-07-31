#include "soft_hci.h"

#include <cstring>

namespace waydroid_bt {

namespace {
constexpr uint16_t kOpReset = 0x0C03;
constexpr uint16_t kOpReadBufferSize = 0x1005;
constexpr uint16_t kOpReadBdAddr = 0x1009;
constexpr uint16_t kOpReadLocalVersion = 0x1001;
constexpr uint16_t kOpReadLocalSupportedCommands = 0x1002;
constexpr uint16_t kOpReadLocalSupportedFeatures = 0x1003;
constexpr uint16_t kOpSetEventMask = 0x0C01;
constexpr uint16_t kOpWriteLeHostSupport = 0x0C6D;
constexpr uint16_t kOpLeSetEventMask = 0x2001;
constexpr uint16_t kOpLeReadBufferSize = 0x2002;       // V1
constexpr uint16_t kOpLeReadLocalSupportedFeatures = 0x2003;
constexpr uint16_t kOpLeSetAdvertisingParameters = 0x2006;
constexpr uint16_t kOpLeReadAdvertisingChannelTxPower = 0x2007;
constexpr uint16_t kOpLeSetAdvertisingData = 0x2008;
constexpr uint16_t kOpLeSetScanResponseData = 0x2009;
constexpr uint16_t kOpLeSetAdvertisingEnable = 0x200A;
constexpr uint16_t kOpLeSetScanParameters = 0x200B;
constexpr uint16_t kOpLeSetScanEnable = 0x200C;
constexpr uint16_t kOpLeCreateConnection = 0x200D;
constexpr uint16_t kOpLeCreateConnectionCancel = 0x200E;
constexpr uint16_t kOpLeSetRandomAddress = 0x2005;
constexpr uint16_t kOpLeReadWhiteListSize = 0x200F;  // filter accept list
constexpr uint16_t kOpLeClearWhiteList = 0x2010;
constexpr uint16_t kOpLeAddDeviceToWhiteList = 0x2011;
constexpr uint16_t kOpLeRemoveDeviceFromWhiteList = 0x2012;
constexpr uint16_t kOpLeReadSupportedStates = 0x201C;
constexpr uint16_t kOpLeReadRemoteUsedFeatures = 0x2016;
constexpr uint16_t kOpLeConnUpdate = 0x2013;
constexpr uint16_t kOpLeEncrypt = 0x2017;
constexpr uint16_t kOpLeRand = 0x2018;
constexpr uint16_t kOpLeStartEncryption = 0x2019;
constexpr uint16_t kOpLeLongTermKeyRequestReply = 0x201A;
constexpr uint16_t kOpLeLongTermKeyRequestNegativeReply = 0x201B;
constexpr uint16_t kOpLeReadChannelMap = 0x2015;
constexpr uint16_t kOpLeReadBufferSizeV1 = 0x2002;
constexpr uint16_t kOpLeReadMaximumDataLength = 0x202F;
constexpr uint16_t kOpLeReadSuggestedDefaultDataLength = 0x2023;
constexpr uint16_t kOpLeSetDefaultPhy = 0x2031;
constexpr uint16_t kOpReadLocalExtendedFeatures = 0x1004;
constexpr uint16_t kOpWriteSimplePairingMode = 0x0C56;
constexpr uint16_t kOpWriteSecureConnectionsHostSupport = 0x0C7A;
constexpr uint16_t kOpReadLocalName = 0x0C14;
constexpr uint16_t kOpWriteLocalName = 0x0C13;
constexpr uint16_t kOpReadClassOfDevice = 0x0C23;
constexpr uint16_t kOpWriteClassOfDevice = 0x0C24;
constexpr uint16_t kOpWriteInquiryScanActivity = 0x0C1E;
constexpr uint16_t kOpWritePageScanActivity = 0x0C1C;
constexpr uint16_t kOpWriteScanEnable = 0x0C1A;
constexpr uint16_t kOpInquiry = 0x0401;
constexpr uint16_t kOpInquiryCancel = 0x0402;
constexpr uint16_t kOpRemoteNameRequest = 0x0419;
constexpr uint16_t kOpRemoteNameRequestCancel = 0x041A;
constexpr uint16_t kOpAuthenticationRequested = 0x0411;
constexpr uint16_t kOpReadRemoteVersionInformation = 0x041D;
constexpr uint16_t kOpReadRemoteSupportedFeatures = 0x041B;
constexpr uint16_t kOpReadRemoteExtendedFeatures = 0x041C;
constexpr uint16_t kOpCreateConnection = 0x0405;
constexpr uint16_t kOpDisconnect = 0x0406;
constexpr uint16_t kOpCreateConnectionCancel = 0x0408;
// LE Extended Scan (BT 5) — Settings / GD may use these instead of 0x200C
constexpr uint16_t kOpLeSetExtendedScanParameters = 0x2041;
constexpr uint16_t kOpLeSetExtendedScanEnable = 0x2042;
constexpr uint16_t kOpDeleteStoredLinkKey = 0x0C12;
constexpr uint16_t kOpWriteDefaultErroneousDataReporting = 0x0C5B;
constexpr uint16_t kOpHostBufferSize = 0x0C33;
constexpr uint16_t kOpSetEventFilter = 0x0C05;
constexpr uint16_t kOpWriteInquiryMode = 0x0C45;
constexpr uint16_t kOpWritePageScanType = 0x0C47;
constexpr uint16_t kOpWriteInquiryScanType = 0x0C43;
constexpr uint16_t kOpReadVoiceSetting = 0x0C25;
constexpr uint16_t kOpWriteVoiceSetting = 0x0C26;
constexpr uint16_t kOpWriteCurrentIacLap = 0x0C3A;
constexpr uint16_t kOpWriteExtendedInquiryResponse = 0x0C52;
constexpr uint16_t kOpWriteSimplePairingDebugMode = 0x1804;
// Vendor: LE_Get_Vendor_Capabilities (OGF 0x3F OCF 0x153) = 0xFD53
constexpr uint16_t kOpLeGetVendorCapabilities = 0xFD53;
// LE_Read_Buffer_Size_V2 = 0x2060 — deliberately NOT claimed in supported cmds
constexpr uint16_t kOpLeReadBufferSizeV2 = 0x2060;
constexpr uint16_t kOpLeReadResolvingListSize = 0x202D;
constexpr uint16_t kOpLeReadMaximumAdvertisingDataLength = 0x203A;
constexpr uint16_t kOpLeReadNumberOfSupportedAdvertisingSets = 0x203B;
constexpr uint16_t kOpLeReadPeriodicAdvertiserListSize = 0x2047;
constexpr uint16_t kOpLeSetHostFeature = 0x2074;

// Supported Commands bit layout (HCI Vol 4 Part E 6.27 / OpCodeIndex in AOSP):
// We only claim commands we implement with correct return sizes so Controller
// does not probe optional LE_READ_* that we would mis-answer.
void fill_supported_commands(Packet& rp) {
  // rp[0] = status already set; rp[1..64] = 64 command octets
  auto set_bit = [&](unsigned index) {
    // AOSP OpCodeIndex: byte = index/10, bit = index%10
    unsigned byte_index = index / 10;
    unsigned bit_index = index % 10;
    if (byte_index < 64) {
      rp[1 + byte_index] |= static_cast<uint8_t>(1u << bit_index);
    }
  };
  // Core init path (indices from bluetooth/hci/hci_packets.pdl / OpCodeIndex)
  // RESET = 0? Actually mapping uses named OpCodeIndex — use well-known bits
  // from a typical BLE controller. Safer: set only a minimal known set via
  // explicit octets that match AOSP GD checks used at Controller::Start.
  //
  // Controller::is_supported uses OpCodeIndex enum. Key optional probes:
  //   LE_READ_BUFFER_SIZE_V2, LE_READ_RESOLVING_LIST_SIZE,
  //   LE_READ_MAXIMUM_DATA_LENGTH, LE_READ_SUGGESTED_DEFAULT_DATA_LENGTH,
  //   LE_READ_MAXIMUM_ADVERTISING_DATA_LENGTH, ...
  // We leave those bits clear. Claim classic init + LE v1 buffer + whitelist.
  //
  // Practical approach used by many soft controllers: zero all, then set
  // bits for commands we actually handle correctly (by HCI bit positions
  // from Core Spec Table "List Of Supported Commands").
  //
  // Octet 0: Inquiry(0) ... Disconnect(5) ... — not needed for BLE bring-up
  // Octet 5 bit 7 / etc. — use a conservative real-device-like mask focused
  // on info commands (Read Local *) and LE controller setup.

  // Read Local Version Information — Octet 14, bit 3
  rp[1 + 14] |= (1u << 3);
  // Read Local Supported Commands — Octet 14, bit 4
  rp[1 + 14] |= (1u << 4);
  // Read Local Supported Features — Octet 14, bit 5
  rp[1 + 14] |= (1u << 5);
  // Read Local Extended Features — Octet 14, bit 6
  rp[1 + 14] |= (1u << 6);
  // Read Buffer Size — Octet 14, bit 7
  rp[1 + 14] |= (1u << 7);
  // Read BD_ADDR — Octet 15, bit 1
  rp[1 + 15] |= (1u << 1);
  // Reset — Octet 5, bit 7
  rp[1 + 5] |= (1u << 7);
  // Set Event Mask — Octet 5, bit 6
  rp[1 + 5] |= (1u << 6);
  // Write LE Host Support — Octet 24, bit 5? (varies) — claim host support writes
  // LE Set Event Mask — Octet 25, bit 0? Claim broad LE controller setup range carefully.

  // LE Read Buffer Size (V1) — Octet 27, bit 7? Spec:
  // Supported Commands octet 25 bit 0 = LE Set Event Mask
  // octet 25 bit 1 = LE Read Buffer Size
  // octet 25 bit 2 = LE Read Local Supported Features
  // octet 25 bit 3 = LE Set Random Address
  // ...
  // octet 26 bit 0 = LE Read White List Size
  // octet 26 bit 7 = LE Read Supported States
  rp[1 + 25] |= 0xFF;  // LE event mask, buffer size v1, features, random addr, adv, scan...
  rp[1 + 26] |= 0xFF;  // whitelist, create conn, supported states, etc.
  // Do NOT set LE Read Buffer Size V2 (introduced later — typically a higher
  // octet). Leaving zeros elsewhere keeps LE_READ_BUFFER_SIZE_V2 unsupported.

  // Write Simple Pairing Mode, Secure Connections Host Support, names, CoD
  rp[1 + 18] |= 0xFF;
  rp[1 + 19] |= 0xFF;
  rp[1 + 20] |= 0xFF;
  rp[1 + 21] |= 0xFF;
  rp[1 + 22] |= 0xFF;
  rp[1 + 23] |= 0xFF;
  rp[1 + 24] |= 0x3F;  // avoid claiming every LE 5.x optional
}
}  // namespace

SoftHci::SoftHci(Packet bd_addr) : bd_addr_(std::move(bd_addr)) {
  if (bd_addr_.size() != 6) {
    bd_addr_ = {0x10, 0xCE, 0xD0, 0x6B, 0xCA, 0x10};
  }
}

void SoftHci::set_event_sink(EventSink sink) {
  std::lock_guard<std::mutex> lock(mu_);
  sink_ = std::move(sink);
}

void SoftHci::set_scan_enable_hook(ScanEnableHook hook) {
  std::lock_guard<std::mutex> lock(mu_);
  scan_hook_ = std::move(hook);
}

void SoftHci::set_disconnect_hook(DisconnectHook hook) {
  std::lock_guard<std::mutex> lock(mu_);
  disconnect_hook_ = std::move(hook);
}

void SoftHci::set_le_create_connection_hook(LeCreateConnectionHook hook) {
  std::lock_guard<std::mutex> lock(mu_);
  le_connect_hook_ = std::move(hook);
}

void SoftHci::reset() {
  std::lock_guard<std::mutex> lock(mu_);
  open_ = true;
  le_scan_active_ = false;
  inquiry_active_ = false;
  le_create_pending_ = false;
  accept_list_last_valid_ = false;
  accept_list_last_type_ = 0;
  std::memset(accept_list_last_addr_, 0, 6);
  for (size_t i = 0; i < kAcceptListMax; i++) {
    accept_list_[i] = AcceptListEntry{};
  }
}

void SoftHci::notify_scan(bool enable) {
  ScanEnableHook hook;
  {
    std::lock_guard<std::mutex> lock(mu_);
    hook = scan_hook_;
  }
  if (hook) {
    hook(enable);
  }
}

bool SoftHci::inquiry_active() const {
  std::lock_guard<std::mutex> lock(mu_);
  return inquiry_active_;
}

bool SoftHci::le_create_pending() const {
  std::lock_guard<std::mutex> lock(mu_);
  return le_create_pending_;
}

void SoftHci::inject_le_advertising_report(const uint8_t addr_le[6], uint8_t addr_type, int8_t rssi,
                                           const Packet& adv_data, uint8_t event_type) {
  emit(make_le_advertising_report(addr_le, addr_type, rssi, adv_data, event_type));
}

void SoftHci::inject_extended_inquiry_result(const uint8_t addr_le[6], int8_t rssi,
                                             const std::string& name) {
  emit(make_extended_inquiry_result(addr_le, rssi, name));
}

void SoftHci::inject_bridged_device(const uint8_t addr_le[6], uint8_t addr_type, int8_t rssi,
                                    const Packet& adv_data, const std::string& name,
                                    uint8_t event_type, bool inject_eir) {
  // AOSP GD le_scanning_manager (process_advertising_package_content):
  //   ADV_IND / ADV_SCAN_IND are scannable → cache payload and WAIT for SCAN_RESPONSE
  //   before OnScanResult. Soft HCI has no radio, so without a synthetic scan
  //   response every connectable adv is dropped → Flowlog "0 results" / sensors not found
  //   even when we inject PRS39739 correctly.
  // HCI Advertising_Event_Type: 0x00 ADV_IND, 0x03 NONCONN, 0x04 SCAN_RESPONSE.
  constexpr uint8_t kAdvInd = 0x00;
  constexpr uint8_t kAdvScanInd = 0x02;
  constexpr uint8_t kScanRsp = 0x04;

  if (event_type == kAdvInd || event_type == kAdvScanInd) {
    inject_le_advertising_report(addr_le, addr_type, rssi, adv_data, event_type);
    // Complete the scannable pair so GD delivers OnScanResult (name in either PDU).
    inject_le_advertising_report(addr_le, addr_type, rssi, adv_data, kScanRsp);
  } else {
    inject_le_advertising_report(addr_le, addr_type, rssi, adv_data, event_type);
  }
  // EIR is optional: classic pair path on BLE-only devices crashed Fluoride (Hue).
  if (inject_eir) {
    inject_extended_inquiry_result(addr_le, rssi, name);
  }
}

void SoftHci::inject_le_connection_complete(uint8_t status, uint16_t handle, uint8_t role,
                                            uint8_t peer_addr_type, const uint8_t peer_addr_le[6]) {
  {
    std::lock_guard<std::mutex> lock(mu_);
    le_create_pending_ = false;
  }
  emit(make_le_connection_complete(status, handle, role, peer_addr_type, peer_addr_le));
}

Packet SoftHci::make_disconnection_complete(uint16_t handle, uint8_t reason, uint8_t status) {
  // Event 0x05 Disconnection Complete: status(1) + handle(2) + reason(1)
  Packet e;
  e.push_back(0x05);
  e.push_back(0x04);
  e.push_back(status);
  e.push_back(static_cast<uint8_t>(handle & 0xff));
  e.push_back(static_cast<uint8_t>((handle >> 8) & 0xff));
  e.push_back(reason);
  return e;
}

void SoftHci::inject_disconnection_complete(uint16_t handle, uint8_t reason) {
  emit(make_disconnection_complete(handle, reason, 0x00));
}

bool SoftHci::parse_le_create_connection_peer(const uint8_t* params, size_t plen,
                                              uint8_t peer_addr_le[6], uint8_t* peer_addr_type,
                                              uint8_t* filter_policy_out) {
  // LE Create Connection (7.8.12): scan_int(2) scan_win(2) filter(1) peer_type(1) peer(6) ...
  if (params == nullptr || plen < 12 || peer_addr_le == nullptr) {
    return false;
  }
  if (filter_policy_out) {
    *filter_policy_out = params[4];
  }
  if (peer_addr_type) {
    *peer_addr_type = params[5];
  }
  for (int i = 0; i < 6; i++) {
    peer_addr_le[i] = params[6 + i];
  }
  return true;
}

bool SoftHci::resolve_le_create_peer(const uint8_t* params, size_t plen, uint8_t peer_addr_le[6],
                                     uint8_t* peer_addr_type) {
  uint8_t filter_policy = 0;
  uint8_t cmd_type = 0;
  uint8_t cmd_addr[6] = {};
  if (!parse_le_create_connection_peer(params, plen, cmd_addr, &cmd_type, &filter_policy)) {
    return false;
  }
  auto is_zero = [](const uint8_t a[6]) {
    return a[0] == 0 && a[1] == 0 && a[2] == 0 && a[3] == 0 && a[4] == 0 && a[5] == 0;
  };
  // Policy 0x00 uses Peer_Address; policy 0x01 uses Filter Accept List (addr often zero).
  if (filter_policy == 0x00 && !is_zero(cmd_addr)) {
    if (peer_addr_type) *peer_addr_type = cmd_type;
    std::memcpy(peer_addr_le, cmd_addr, 6);
    return true;
  }
  std::lock_guard<std::mutex> lock(mu_);
  if (accept_list_last_valid_) {
    if (peer_addr_type) *peer_addr_type = accept_list_last_type_;
    std::memcpy(peer_addr_le, accept_list_last_addr_, 6);
    return true;
  }
  for (size_t i = 0; i < kAcceptListMax; i++) {
    if (accept_list_[i].in_use) {
      if (peer_addr_type) *peer_addr_type = accept_list_[i].addr_type;
      std::memcpy(peer_addr_le, accept_list_[i].addr_le, 6);
      return true;
    }
  }
  // Fall back to command fields even if zero (caller will fail host connect).
  if (peer_addr_type) *peer_addr_type = cmd_type;
  std::memcpy(peer_addr_le, cmd_addr, 6);
  return !is_zero(cmd_addr);
}

Packet SoftHci::make_le_connection_complete(uint8_t status, uint16_t handle, uint8_t role,
                                            uint8_t peer_addr_type, const uint8_t peer_addr_le[6]) {
  // HCI LE Meta Event 0x3E / Subevent 0x01 LE Connection Complete.
  // plen is computed from payload size so it cannot drift from body length.
  Packet e;
  e.push_back(0x3E);
  e.push_back(0x00);  // Parameter_Total_Length placeholder; set after body
  e.push_back(0x01);  // LE Connection Complete
  e.push_back(status);
  e.push_back(static_cast<uint8_t>(handle & 0xFF));
  e.push_back(static_cast<uint8_t>((handle >> 8) & 0xFF));
  e.push_back(role);
  e.push_back(peer_addr_type);
  for (int i = 0; i < 6; i++) {
    e.push_back(peer_addr_le ? peer_addr_le[i] : 0);
  }
  // Conn_Interval, Latency, Supervision_Timeout, Master_Clock_Accuracy
  e.push_back(0x18);
  e.push_back(0x00);  // interval 0x0018
  e.push_back(0x00);
  e.push_back(0x00);  // latency 0
  e.push_back(0x48);
  e.push_back(0x00);  // supervision 0x0048
  e.push_back(0x00);  // MCA
  // sub(1)+status(1)+handle(2)+role(1)+atype(1)+addr(6)+int(2)+lat(2)+sup(2)+MCA(1) = 19 = 0x13
  e[1] = static_cast<uint8_t>(e.size() - 2);
  return e;
}

Packet SoftHci::make_le_advertising_report(const uint8_t addr_le[6], uint8_t addr_type, int8_t rssi,
                                           const Packet& adv_data, uint8_t event_type) {
  // HCI LE Meta Event 0x3E / Subevent 0x02 LE Advertising Report
  Packet e;
  const size_t data_len = adv_data.size() > 31 ? 31 : adv_data.size();
  // params: subevent(1) + num(1) + event_type(1) + addr_type(1) + addr(6) + dlen(1) + data + rssi(1)
  const uint8_t plen = static_cast<uint8_t>(2 + 1 + 1 + 6 + 1 + data_len + 1);
  e.push_back(0x3E);
  e.push_back(plen);
  e.push_back(0x02);  // LE Advertising Report
  e.push_back(0x01);  // Num_Reports
  e.push_back(event_type);
  e.push_back(addr_type);
  for (int i = 0; i < 6; i++) {
    e.push_back(addr_le[i]);
  }
  e.push_back(static_cast<uint8_t>(data_len));
  e.insert(e.end(), adv_data.begin(), adv_data.begin() + static_cast<std::ptrdiff_t>(data_len));
  e.push_back(static_cast<uint8_t>(rssi));
  return e;
}

Packet SoftHci::make_extended_inquiry_result(const uint8_t addr_le[6], int8_t rssi,
                                             const std::string& name) {
  // Event 0x2F Extended Inquiry Result
  // Num_Responses(1)=1, BD_ADDR(6), Page_Scan_Repetition_Mode(1), Reserved(2),
  // Class_Of_Device(3), Clock_Offset(2), RSSI(1), EIR_Data(240)
  Packet eir(240, 0x00);
  if (!name.empty()) {
    size_t nlen = name.size();
    if (nlen > 248) nlen = 248;
    // Complete Local Name AD: len, type 0x09, name
    eir[0] = static_cast<uint8_t>(1 + nlen);
    eir[1] = 0x09;
    std::memcpy(eir.data() + 2, name.data(), nlen);
  }
  Packet e;
  e.push_back(0x2F);
  e.push_back(255);  // parameter total length
  e.push_back(0x01);  // Num_Responses
  for (int i = 0; i < 6; i++) {
    e.push_back(addr_le[i]);
  }
  e.push_back(0x01);  // Page_Scan_Repetition_Mode R1
  e.push_back(0x00);  // Reserved
  e.push_back(0x00);
  e.push_back(0x0C);  // CoD: phone-ish
  e.push_back(0x02);
  e.push_back(0x7C);
  e.push_back(0x00);  // Clock_Offset
  e.push_back(0x00);
  e.push_back(static_cast<uint8_t>(rssi));
  e.insert(e.end(), eir.begin(), eir.end());
  return e;
}

Packet SoftHci::make_inquiry_complete(uint8_t status) {
  // Event 0x01 Inquiry Complete
  Packet e;
  e.push_back(0x01);
  e.push_back(0x01);
  e.push_back(status);
  return e;
}

void SoftHci::emit(const Packet& event) {
  EventSink sink;
  {
    std::lock_guard<std::mutex> lock(mu_);
    sink = sink_;
  }
  if (sink) {
    sink(event);
  }
}

uint16_t SoftHci::opcode_of(const Packet& cmd) {
  if (cmd.size() < 2) {
    return 0;
  }
  return static_cast<uint16_t>(cmd[0] | (cmd[1] << 8));
}

Packet SoftHci::make_command_complete(uint16_t opcode, const Packet& return_params) {
  // Event: 0x0E Command Complete
  // params: Num_HCI_Command_Packets (1), Opcode (2), Return_Parameters...
  Packet e;
  e.push_back(0x0E);
  e.push_back(static_cast<uint8_t>(1 + 2 + return_params.size()));
  e.push_back(0x01);  // num command packets (credit)
  e.push_back(static_cast<uint8_t>(opcode & 0xFF));
  e.push_back(static_cast<uint8_t>((opcode >> 8) & 0xFF));
  e.insert(e.end(), return_params.begin(), return_params.end());
  return e;
}

Packet SoftHci::make_command_status(uint8_t status, uint16_t opcode) {
  // Event: 0x0F Command Status
  Packet e;
  e.push_back(0x0F);
  e.push_back(4);
  e.push_back(status);
  e.push_back(0x01);
  e.push_back(static_cast<uint8_t>(opcode & 0xFF));
  e.push_back(static_cast<uint8_t>((opcode >> 8) & 0xFF));
  return e;
}

void SoftHci::handle_command(const Packet& cmd) {
  if (cmd.size() < 3) {
    return;
  }
  const uint16_t opcode = opcode_of(cmd);
  const uint8_t plen = cmd[2];
  const uint8_t* params = (cmd.size() > 3) ? cmd.data() + 3 : nullptr;

  auto complete_status = [&](uint8_t status = 0x00) {
    emit(make_command_complete(opcode, Packet{status}));
  };

  switch (opcode) {
    case kOpReset:
      reset();
      complete_status(0x00);
      break;
    case kOpReadBdAddr: {
      Packet rp;
      rp.push_back(0x00);  // status
      // BD_ADDR is little-endian in HCI
      for (int i = 0; i < 6; i++) {
        rp.push_back(bd_addr_[i]);
      }
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpReadLocalVersion: {
      // status, hci_version, hci_revision(2), lmp_version, manufacturer(2), lmp_subversion(2)
      // HCI 5.0 (0x09), LMP 5.0, manufacturer 0x001D (Qualcomm-ish / matches soft)
      Packet rp = {0x00, 0x09, 0x00, 0x00, 0x09, 0x1D, 0x00, 0x00, 0x00};
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpReadBufferSize: {
      // status, acl_len(2), sco_len, acl_num(2), sco_num(2)
      Packet rp = {0x00, 0xA0, 0x02, 0xFF, 0x08, 0x00, 0x01, 0x00};
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpReadLocalSupportedCommands: {
      Packet rp(65, 0x00);
      rp[0] = 0x00;  // status
      fill_supported_commands(rp);
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpReadLocalSupportedFeatures: {
      // status + 8 LMP feature bytes.
      // Bit 38 = LE Supported (Controller) → byte 4 bit 6 = 0x40
      // Bit 37 = BR/EDR Not Supported optional; keep dual-mode-ish.
      // Use a conservative BREDR+LE feature page (no SC on page 0).
      Packet rp = {0x00, 0xFF, 0xFE, 0x8F, 0xFE, 0xDB, 0xFF, 0x7B, 0x87};
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpReadLocalExtendedFeatures: {
      // CRITICAL: Maximum_Page_Number must be 0 unless we answer every page
      // correctly. Returning max=1 while always echoing page 0 hangs GD
      // Controller::Start on features_future (infinite re-query).
      //
      // CRITICAL: Fluoride GD Controller::GetLocalFeatures(page) is filled
      // ONLY from this command (not Read Local Supported Features). Page 0
      // must carry the real LMP feature mask — including bit 38 LE Supported.
      // Returning zeros makes SupportsBle() false → ble_acceptlist_size()==0
      // → bta_gattc_srcb_alloc fails → "No resources to open a new connection"
      // (GATT status 128) before LE Create Connection is ever sent.
      uint8_t page = (plen >= 1 && params) ? params[0] : 0;
      // Same page-0 mask as Read Local Supported Features (FF FE 8F FE DB FF 7B 87).
      static const uint8_t kPage0Features[8] = {0xFF, 0xFE, 0x8F, 0xFE,
                                               0xDB, 0xFF, 0x7B, 0x87};
      Packet rp(11, 0x00);
      rp[0] = 0x00;   // status
      rp[1] = page;   // page number echoed
      rp[2] = 0x00;   // maximum page number = 0 (only page 0 exists)
      if (page == 0) {
        for (int i = 0; i < 8; i++) rp[3 + i] = kPage0Features[i];
      }
      // page > 0: leave feature bytes zero (should not be requested with max=0)
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpLeReadBufferSize: {
      // status, le_acl_data_packet_length(2), total_num_le_acl_data_packets
      Packet rp = {0x00, 0xFB, 0x00, 0x06};
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpLeReadBufferSizeV2: {
      // status + LE ACL len(2) + LE ACL num + ISO len(2) + ISO num
      Packet rp = {0x00, 0xFB, 0x00, 0x06, 0xFB, 0x00, 0x06};
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpLeReadLocalSupportedFeatures: {
      // status + 8 LE feature bytes.
      // Bit 0 Encryption, 1 Conn Param Req, 4 Ping — keep basic LE only.
      // Clear bit 5 (Data Length Extension), 6 (LL Privacy), 12 (Ext Adv),
      // 13 (Periodic Adv), 28 (CIS Central) so Controller skips optional reads.
      Packet rp = {0x00, 0x1F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpLeReadSupportedStates: {
      Packet rp = {0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x03};
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpLeReadWhiteListSize: {
      Packet rp = {0x00, 0x10};
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpLeReadResolvingListSize: {
      Packet rp = {0x00, 0x10};
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpLeReadSuggestedDefaultDataLength: {
      // status, SuggestedMaxTxOctets(2), SuggestedMaxTxTime(2)
      Packet rp = {0x00, 0x1B, 0x00, 0x48, 0x08};
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpLeReadMaximumDataLength: {
      // status + 4x uint16
      Packet rp = {0x00, 0xFB, 0x00, 0x48, 0x08, 0xFB, 0x00, 0x48, 0x08};
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpLeReadMaximumAdvertisingDataLength: {
      Packet rp = {0x00, 0x1F, 0x00};  // 31
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpLeReadNumberOfSupportedAdvertisingSets: {
      Packet rp = {0x00, 0x01};
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpLeReadPeriodicAdvertiserListSize: {
      Packet rp = {0x00, 0x00};
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpLeSetHostFeature:
      complete_status(0x00);
      break;
    case kOpLeGetVendorCapabilities: {
      // Return invalid/minimal so GD marks vendor caps unsupported (is_supported_=0).
      // status SUCCESS with empty-ish body → IsValid may fail → OK (handler defaults).
      complete_status(0x01);  // Unknown HCI Command-ish / not supported
      break;
    }
    case kOpLeReadAdvertisingChannelTxPower: {
      // status + Transmit_Power_Level (signed dBm)
      Packet rp = {0x00, 0x00};
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpLeSetAdvertisingParameters:
    case kOpLeSetAdvertisingData:
    case kOpLeSetScanResponseData:
    case kOpLeSetScanParameters:
      complete_status(0x00);
      break;
    case kOpLeSetScanEnable: {
      // LE_Scan_Enable, Filter_Duplicates
      const uint8_t enable = (plen >= 1 && params) ? params[0] : 0;
      complete_status(0x00);
      {
        std::lock_guard<std::mutex> lock(mu_);
        le_scan_active_ = enable != 0;
      }
      notify_scan(enable != 0 || inquiry_active());
      break;
    }
    case kOpLeSetExtendedScanParameters:
      complete_status(0x00);
      break;
    case kOpLeSetExtendedScanEnable: {
      // Enable (1), Filter_Duplicates (1), Duration (2), Period (2)
      const uint8_t enable = (plen >= 1 && params) ? params[0] : 0;
      complete_status(0x00);
      {
        std::lock_guard<std::mutex> lock(mu_);
        le_scan_active_ = enable != 0;
      }
      notify_scan(enable != 0 || inquiry_active());
      break;
    }
    case kOpInquiry: {
      // Inquiry is Command Status (not Complete); results are async events.
      // Used by Settings startDiscovery() / "Pair new device".
      emit(make_command_status(0x00, opcode));
      {
        std::lock_guard<std::mutex> lock(mu_);
        inquiry_active_ = true;
      }
      notify_scan(true);
      break;
    }
    case kOpInquiryCancel: {
      complete_status(0x00);
      bool still_le = false;
      {
        std::lock_guard<std::mutex> lock(mu_);
        inquiry_active_ = false;
        still_le = le_scan_active_;
      }
      emit(make_inquiry_complete(0x00));
      notify_scan(still_le);
      break;
    }
    case kOpRemoteNameRequest: {
      // Vol 4 Part E 7.1.19: Command Status, then event 0x07 Remote Name Request Complete.
      // Just-Works LE path: do NOT succeed with a fake classic name ("SoftBT-Remote").
      // That name previously drove pinRequestCallback and a classic PIN hang on LE peers.
      // Fail cleanly with Page Timeout (0x04) so the stack stays alive without PIN UI.
      emit(make_command_status(0x00, opcode));
      Packet e;
      e.push_back(0x07);
      e.push_back(0xFF);  // Status(1)+BD_ADDR(6)+Name(248)=255
      e.push_back(0x04);  // Page Timeout — classic name failed; no PIN dialog name
      for (int i = 0; i < 6; i++) {
        e.push_back(params && plen >= 6 ? params[i] : 0);
      }
      for (size_t i = 0; i < 248; i++) {
        e.push_back(0x00);  // empty remote name
      }
      emit(e);
      break;
    }
    case kOpRemoteNameRequestCancel:
      complete_status(0x00);
      break;
    case kOpCreateConnection: {
      // Classic create: Command Status then Connection Complete fail (no classic radio).
      emit(make_command_status(0x00, opcode));
      Packet e;
      e.push_back(0x03);  // Connection Complete
      e.push_back(0x0B);  // status+handle+bdaddr+link+enc
      e.push_back(0x0E);  // Connection Accept Timeout Exceeded (stack-safe)
      e.push_back(0x00);
      e.push_back(0x00);  // handle
      for (int i = 0; i < 6; i++) {
        e.push_back(params && plen >= 6 ? params[i] : 0);
      }
      e.push_back(0x01);  // link type ACL
      e.push_back(0x00);  // encryption disabled
      emit(e);
      break;
    }
    case kOpCreateConnectionCancel:
      complete_status(0x00);
      break;
    case kOpDisconnect: {
      // Command Status then Disconnection Complete (0x05).
      emit(make_command_status(0x00, opcode));
      uint16_t handle = 0x0040;
      uint8_t reason = 0x16;  // Connection Terminated by Local Host
      if (params && plen >= 2) {
        handle = static_cast<uint16_t>(params[0] | (static_cast<uint16_t>(params[1]) << 8));
      }
      if (params && plen >= 3) {
        reason = params[2];
      }
      // Tear down Soft ATT / host BlueZ link for this handle only (multi-link).
      DisconnectHook dhook;
      {
        std::lock_guard<std::mutex> lock(mu_);
        dhook = disconnect_hook_;
        le_create_pending_ = false;
      }
      if (dhook) {
        dhook(handle, reason);
      }
      emit(make_disconnection_complete(handle, reason, 0x00));
      break;
    }
    case kOpAuthenticationRequested: {
      // Command Status then Authentication Complete fail (no link).
      emit(make_command_status(0x00, opcode));
      Packet e;
      e.push_back(0x06);  // Authentication Complete
      e.push_back(0x03);
      e.push_back(0x06);  // Pin or Key Missing / auth failure-ish
      e.push_back(0x00);
      e.push_back(0x00);  // handle
      emit(e);
      break;
    }
    case kOpLeCreateConnection: {
      // Must not leave Fluoride half-open: Command Status then Connection Complete.
      // GD often: LE_Add_Device_To_Filter_Accept_List then Create Connection with
      // Initiator_Filter_Policy=0x01 (peer address in command is zero).
      uint8_t peer[6] = {};
      uint8_t peer_type = 0;
      const bool resolved = resolve_le_create_peer(params, plen, peer, &peer_type);
      emit(make_command_status(0x00, opcode));
      LeCreateConnectionHook hook;
      {
        std::lock_guard<std::mutex> lock(mu_);
        le_create_pending_ = true;
        if (resolved) {
          std::memcpy(pending_peer_addr_, peer, 6);
          pending_peer_type_ = peer_type;
        }
        hook = le_connect_hook_;
      }
      if (hook && resolved) {
        // Host bridge path: hook will inject_le_connection_complete later.
        hook(peer, peer_type);
      } else {
        // Stack-safe fail: Connection Failed to be Established (0x3E).
        uint8_t zero[6] = {};
        inject_le_connection_complete(0x3E, 0x0000, 0x00, peer_type, resolved ? peer : zero);
      }
      break;
    }
    case kOpLeCreateConnectionCancel: {
      // Spec: Command Complete (not Status) for Cancel.
      complete_status(0x00);
      uint8_t peer[6] = {};
      uint8_t peer_type = 0;
      bool pending = false;
      {
        std::lock_guard<std::mutex> lock(mu_);
        pending = le_create_pending_;
        if (pending) {
          std::memcpy(peer, pending_peer_addr_, 6);
          peer_type = pending_peer_type_;
          le_create_pending_ = false;
        }
      }
      if (pending) {
        // Unknown Connection Identifier — cancel while pending.
        inject_le_connection_complete(0x02, 0x0000, 0x00, peer_type, peer);
      }
      break;
    }
    case kOpReadRemoteVersionInformation: {
      // Vol 4 Part E 7.1.23: Command Status, then event 0x0C Complete.
      // Returning Command Complete (status-only default) crashes GD HciLayer
      // (null deref in handle_command_response<CommandCompleteView>) — Flowlog 133.
      emit(make_command_status(0x00, opcode));
      uint16_t handle = 0x0040;
      if (params && plen >= 2) {
        handle = static_cast<uint16_t>(params[0] | (static_cast<uint16_t>(params[1]) << 8));
      }
      Packet e;
      e.push_back(0x0C);  // Read Remote Version Information Complete
      e.push_back(0x08);  // plen: status+handle+ver+mfg(2)+sub(2)
      e.push_back(0x00);  // status
      e.push_back(static_cast<uint8_t>(handle & 0xff));
      e.push_back(static_cast<uint8_t>((handle >> 8) & 0xff));
      e.push_back(0x09);  // LMP/HCI version 5.0
      e.push_back(0x1D);  // manufacturer (Qualcomm-ish, matches local)
      e.push_back(0x00);
      e.push_back(0x00);  // subversion
      e.push_back(0x00);
      emit(e);
      break;
    }
    case kOpReadRemoteSupportedFeatures: {
      // Command Status + event 0x0B Read Remote Supported Features Complete.
      emit(make_command_status(0x00, opcode));
      uint16_t handle = 0x0040;
      if (params && plen >= 2) {
        handle = static_cast<uint16_t>(params[0] | (static_cast<uint16_t>(params[1]) << 8));
      }
      Packet e;
      e.push_back(0x0B);
      e.push_back(0x0B);  // status+handle+8 features
      e.push_back(0x00);
      e.push_back(static_cast<uint8_t>(handle & 0xff));
      e.push_back(static_cast<uint8_t>((handle >> 8) & 0xff));
      // Same page-0 LMP mask as local Soft HCI features.
      e.push_back(0xFF);
      e.push_back(0xFE);
      e.push_back(0x8F);
      e.push_back(0xFE);
      e.push_back(0xDB);
      e.push_back(0xFF);
      e.push_back(0x7B);
      e.push_back(0x87);
      emit(e);
      break;
    }
    case kOpReadRemoteExtendedFeatures: {
      emit(make_command_status(0x00, opcode));
      uint16_t handle = 0x0040;
      uint8_t page = 0;
      if (params && plen >= 2) {
        handle = static_cast<uint16_t>(params[0] | (static_cast<uint16_t>(params[1]) << 8));
      }
      if (params && plen >= 3) page = params[2];
      Packet e;
      e.push_back(0x23);  // Read Remote Extended Features Complete
      e.push_back(0x0D);  // status+handle+page+max+8 features
      e.push_back(0x00);
      e.push_back(static_cast<uint8_t>(handle & 0xff));
      e.push_back(static_cast<uint8_t>((handle >> 8) & 0xff));
      e.push_back(page);
      e.push_back(0x00);  // max page
      for (int i = 0; i < 8; i++) e.push_back(0x00);
      emit(e);
      break;
    }
    case kOpLeReadRemoteUsedFeatures: {
      // Command Status, then LE Meta / Read Remote Features Complete (sub 0x04).
      // Returning Command Disallowed here aborts Fluoride LE links (Flowlog
      // UNKNOWN_HCI_ERROR / GATT failures after connect).
      emit(make_command_status(0x00, opcode));
      uint16_t handle = 0x0040;
      if (params && plen >= 2) {
        handle = static_cast<uint16_t>(params[0] | (static_cast<uint16_t>(params[1]) << 8));
      }
      Packet e;
      e.push_back(0x3E);
      e.push_back(0x0C);  // sub(1)+status(1)+handle(2)+features(8)=12
      e.push_back(0x04);  // LE Read Remote Features Complete
      e.push_back(0x00);  // status
      e.push_back(static_cast<uint8_t>(handle & 0xff));
      e.push_back(static_cast<uint8_t>((handle >> 8) & 0xff));
      // LE features: encryption + basic set (same as local soft features)
      e.push_back(0x1F);
      e.push_back(0x00);
      e.push_back(0x00);
      e.push_back(0x00);
      e.push_back(0x00);
      e.push_back(0x00);
      e.push_back(0x00);
      e.push_back(0x00);
      emit(e);
      break;
    }
    case kOpLeConnUpdate: {
      // Command Status + LE Connection Update Complete (sub 0x03).
      emit(make_command_status(0x00, opcode));
      uint16_t handle = 0x0040;
      if (params && plen >= 2) {
        handle = static_cast<uint16_t>(params[0] | (static_cast<uint16_t>(params[1]) << 8));
      }
      Packet e;
      e.push_back(0x3E);
      e.push_back(0x0A);  // sub+status+handle+interval+latency+timeout = 10
      e.push_back(0x03);
      e.push_back(0x00);  // status
      e.push_back(static_cast<uint8_t>(handle & 0xff));
      e.push_back(static_cast<uint8_t>((handle >> 8) & 0xff));
      e.push_back(0x18);
      e.push_back(0x00);  // interval
      e.push_back(0x00);
      e.push_back(0x00);  // latency
      e.push_back(0x48);
      e.push_back(0x00);  // supervision timeout
      emit(e);
      break;
    }
    case kOpLeRand: {
      // status + Random_Number(8). Fluoride aborts if status != 0
      // (hciblecmds.cc: "LE Rand return status must be zero").
      Packet rp(9, 0x00);
      rp[0] = 0x00;
      for (int i = 0; i < 8; i++) rp[1 + i] = static_cast<uint8_t>(0xA0 + i);
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpLeEncrypt: {
      // status + Encrypted_Data(16). Soft fixed block so SMP can proceed.
      Packet rp(17, 0x00);
      rp[0] = 0x00;
      for (int i = 0; i < 16; i++) rp[1 + i] = static_cast<uint8_t>(0x10 + i);
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpLeStartEncryption: {
      // Command Status then Encryption Change (0x08) so link can go encrypted.
      emit(make_command_status(0x00, opcode));
      uint16_t handle = 0x0040;
      if (params && plen >= 2) {
        handle = static_cast<uint16_t>(params[0] | (static_cast<uint16_t>(params[1]) << 8));
      }
      Packet e;
      e.push_back(0x08);  // Encryption Change
      e.push_back(0x04);  // status + handle(2) + enabled
      e.push_back(0x00);  // status
      e.push_back(static_cast<uint8_t>(handle & 0xff));
      e.push_back(static_cast<uint8_t>((handle >> 8) & 0xff));
      e.push_back(0x01);  // encryption enabled (AES-CCM for LE)
      emit(e);
      break;
    }
    case kOpLeLongTermKeyRequestReply:
    case kOpLeLongTermKeyRequestNegativeReply:
      // Pairing crypto not implemented — do not pretend success (Hue crash path).
      complete_status(0x0C);  // Command Disallowed
      break;
    case kOpLeReadChannelMap: {
      // status + conn_handle(2) + channel_map(5)
      Packet rp = {0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x1F};
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpReadLocalName: {
      Packet rp(249, 0x00);
      rp[0] = 0x00;
      const char* name = "Waydroid SoftBT";
      std::memcpy(rp.data() + 1, name, std::strlen(name));
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpReadClassOfDevice: {
      Packet rp = {0x00, 0x0C, 0x02, 0x7C};
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpReadVoiceSetting: {
      Packet rp = {0x00, 0x60, 0x00};
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpDeleteStoredLinkKey: {
      // Core Spec Vol 4 Part E 7.3.10: Status (1) + Num_Keys_Deleted (2).
      // Must NOT fall through with status-only opcodes — those need return_params len==1.
      // Returning only Status makes Fluoride log_classic_pairing_command_complete crash.
      Packet rp = {0x00, 0x00, 0x00};
      emit(make_command_complete(opcode, rp));
      break;
    }
    case kOpLeClearWhiteList: {
      {
        std::lock_guard<std::mutex> lock(mu_);
        accept_list_last_valid_ = false;
        accept_list_last_type_ = 0;
        std::memset(accept_list_last_addr_, 0, 6);
        for (size_t i = 0; i < kAcceptListMax; i++) {
          accept_list_[i] = AcceptListEntry{};
        }
      }
      complete_status(0x00);
      break;
    }
    case kOpLeAddDeviceToWhiteList: {
      // Address_Type(1) + Address(6) HCI LE order.
      if (params && plen >= 7) {
        const uint8_t at = params[0];
        const uint8_t* addr = params + 1;
        std::lock_guard<std::mutex> lock(mu_);
        bool stored = false;
        for (size_t i = 0; i < kAcceptListMax; i++) {
          if (!accept_list_[i].in_use) {
            accept_list_[i].in_use = true;
            accept_list_[i].addr_type = at;
            std::memcpy(accept_list_[i].addr_le, addr, 6);
            stored = true;
            break;
          }
          // Update if already present.
          if (accept_list_[i].in_use && accept_list_[i].addr_type == at &&
              std::memcmp(accept_list_[i].addr_le, addr, 6) == 0) {
            stored = true;
            break;
          }
        }
        // Always record last-added for Create Connection with policy=accept-list.
        accept_list_last_valid_ = true;
        accept_list_last_type_ = at;
        std::memcpy(accept_list_last_addr_, addr, 6);
        (void)stored;
      }
      complete_status(0x00);
      break;
    }
    case kOpLeRemoveDeviceFromWhiteList: {
      if (params && plen >= 7) {
        const uint8_t at = params[0];
        const uint8_t* addr = params + 1;
        std::lock_guard<std::mutex> lock(mu_);
        for (size_t i = 0; i < kAcceptListMax; i++) {
          if (accept_list_[i].in_use && accept_list_[i].addr_type == at &&
              std::memcmp(accept_list_[i].addr_le, addr, 6) == 0) {
            accept_list_[i] = AcceptListEntry{};
          }
        }
        if (accept_list_last_valid_ && accept_list_last_type_ == at &&
            std::memcmp(accept_list_last_addr_, addr, 6) == 0) {
          accept_list_last_valid_ = false;
          std::memset(accept_list_last_addr_, 0, 6);
        }
      }
      complete_status(0x00);
      break;
    }
    // Status-only Command Complete group (return_params = Status only).
    // Never graft multi-byte return bodies into this fall-through list.
    case kOpSetEventMask:
    case kOpWriteLeHostSupport:
    case kOpLeSetEventMask:
    case kOpLeSetAdvertisingEnable:
    case kOpLeSetRandomAddress:
    case kOpLeSetDefaultPhy:
    case kOpWriteSimplePairingMode:
    case kOpWriteSecureConnectionsHostSupport:
    case kOpWriteLocalName:
    case kOpWriteClassOfDevice:
    case kOpWriteInquiryScanActivity:
    case kOpWritePageScanActivity:
    case kOpWriteScanEnable:
    case kOpWriteDefaultErroneousDataReporting:
    case kOpHostBufferSize:
    case kOpSetEventFilter:
    case kOpWriteInquiryMode:
    case kOpWritePageScanType:
    case kOpWriteInquiryScanType:
    case kOpWriteVoiceSetting:
    case kOpWriteCurrentIacLap:
    case kOpWriteExtendedInquiryResponse:
    case kOpWriteSimplePairingDebugMode:
      complete_status(0x00);
      break;
    default:
      // Unknown: Command Disallowed rather than success — avoids malformed
      // pairing command-complete crashes (log_classic_pairing_command_complete).
      complete_status(0x0C);
      break;
  }
}

}  // namespace waydroid_bt
