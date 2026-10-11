#include <algorithm>
#include <sys/socket.h>
#include <unistd.h>
// Host-side unit tests for SoftHci + Soft ATT pure helpers (no Android HIDL).
#include "bridge_ipc.h"
#include "soft_hci.h"
#include "soft_hci_att.h"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using waydroid_bt::BridgeAdv;
using waydroid_bt::BridgeIpc;
using waydroid_bt::Packet;
using waydroid_bt::SoftAttLink;
using waydroid_bt::SoftHci;

static void test_opcode_of() {
  Packet cmd = {0x03, 0x0C, 0x00};  // Reset
  assert(SoftHci::opcode_of(cmd) == 0x0C03);
  printf("ok opcode_of\n");
}

static void test_command_complete_shape() {
  Packet rp = {0x00, 0x11, 0x22};
  Packet e = SoftHci::make_command_complete(0x1009, rp);
  assert(e.size() >= 5);
  assert(e[0] == 0x0E);
  assert(e[1] == static_cast<uint8_t>(1 + 2 + rp.size()));
  assert(e[2] == 0x01);
  assert(e[3] == 0x09);
  assert(e[4] == 0x10);
  assert(e[5] == 0x00);
  printf("ok command_complete_shape\n");
}

static void test_reset_and_bd_addr() {
  SoftHci hci({0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF});
  std::vector<Packet> events;
  hci.set_event_sink([&](const Packet& e) { events.push_back(e); });

  hci.handle_command({0x03, 0x0C, 0x00});  // Reset
  assert(events.size() == 1);
  assert(events[0][0] == 0x0E);

  events.clear();
  hci.handle_command({0x09, 0x10, 0x00});  // Read BD_ADDR
  assert(events.size() == 1);
  const Packet& e = events[0];
  // type+len+num+opc+status+addr = 12
  assert(e.size() == 12);
  assert(e[0] == 0x0E);
  assert(e[5] == 0x00);
  assert(e[6] == 0xAA && e[11] == 0xFF);
  printf("ok reset_and_bd_addr\n");
}

static void test_unknown_still_completes() {
  SoftHci hci;
  int n = 0;
  hci.set_event_sink([&](const Packet&) { n++; });
  hci.handle_command({0x00, 0x00, 0x00});
  assert(n == 1);
  printf("ok unknown_still_completes\n");
}

static void test_extended_features_max_page_zero() {
  SoftHci hci;
  std::vector<Packet> events;
  hci.set_event_sink([&](const Packet& e) { events.push_back(e); });
  // Read Local Extended Features page 0
  hci.handle_command({0x04, 0x10, 0x01, 0x00});
  assert(events.size() == 1);
  const Packet& e = events[0];
  // 0E, len, num, opc_lo, opc_hi, status, page, max_page, features[8]
  assert(e[0] == 0x0E);
  assert(e[5] == 0x00);  // status
  assert(e[6] == 0x00);  // page
  assert(e[7] == 0x00);  // max page MUST be 0 (Controller re-queries if > page)
  // features[8] start at e[8]; must match page-0 LMP mask (bit 38 = LE Supported)
  assert(e.size() >= 16);
  assert(e[8] == 0xFF && e[9] == 0xFE && e[10] == 0x8F && e[11] == 0xFE);
  assert(e[12] == 0xDB && e[13] == 0xFF && e[14] == 0x7B && e[15] == 0x87);
  // Bit 38 → features byte 4 bit 6
  assert((e[12] & (1u << 6)) != 0);
  // page 1 request still echoes page and max=0; features zero (no such page)
  events.clear();
  hci.handle_command({0x04, 0x10, 0x01, 0x01});
  assert(events[0][6] == 0x01);
  assert(events[0][7] == 0x00);
  for (int i = 0; i < 8; i++) assert(events[0][8 + i] == 0x00);
  printf("ok extended_features_max_page_zero\n");
}

static void test_read_remote_version_status_then_event() {
  SoftHci hci;
  std::vector<Packet> events;
  hci.set_event_sink([&](const Packet& e) { events.push_back(e); });
  // Read Remote Version Information handle 0x0040
  hci.handle_command({0x1D, 0x04, 0x02, 0x40, 0x00});
  assert(events.size() == 2);
  // Command Status 0x0F: status, Num_HCI_Command_Packets, opcode
  assert(events[0][0] == 0x0F);
  assert(events[0][2] == 0x00);  // status success
  assert(events[0][3] == 0x01);  // num command packets
  assert(events[0][4] == 0x1D && events[0][5] == 0x04);  // opcode
  // Complete event 0x0C
  assert(events[1][0] == 0x0C);
  assert(events[1][2] == 0x00);  // status
  assert(events[1][3] == 0x40 && events[1][4] == 0x00);  // handle
  printf("ok read_remote_version_status_then_event\n");
}

static void test_le_rand_status_zero() {
  SoftHci hci;
  std::vector<Packet> events;
  hci.set_event_sink([&](const Packet& e) { events.push_back(e); });
  // LE Rand opcode 0x2018
  hci.handle_command({0x18, 0x20, 0x00});
  assert(events.size() == 1);
  const Packet& e = events[0];
  assert(e[0] == 0x0E);
  assert(e[5] == 0x00);  // status MUST be 0 (Fluoride aborts otherwise)
  assert(e.size() >= 14);  // 0E len n opc(2) status + 8 random
  printf("ok le_rand_status_zero\n");
}

static void test_controller_init_sequence() {
  // Minimal command sequence matching GD Controller::Start (serial).
  SoftHci hci({0x10, 0xCE, 0xD0, 0x6B, 0xCA, 0x10});
  int n = 0;
  hci.set_event_sink([&](const Packet& e) {
    assert(e[0] == 0x0E);  // command complete
    n++;
  });
  auto send = [&](std::initializer_list<uint8_t> c) {
    hci.handle_command(Packet(c));
  };
  send({0x03, 0x0C, 0x00});              // Reset (HciLayer::Start)
  send({0x01, 0x20, 0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF});  // LE Set Event Mask
  send({0x01, 0x0C, 0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF});  // Set Event Mask
  send({0x6D, 0x0C, 0x02, 0x01, 0x00});  // Write LE Host Support
  send({0x14, 0x0C, 0x00});              // Read Local Name
  send({0x01, 0x10, 0x00});              // Read Local Version
  send({0x02, 0x10, 0x00});              // Read Local Supported Commands
  send({0x03, 0x20, 0x00});              // LE Read Local Supported Features
  send({0x1C, 0x20, 0x00});              // LE Read Supported States
  send({0x04, 0x10, 0x01, 0x00});        // Read Local Extended Features p0
  send({0x05, 0x10, 0x00});              // Read Buffer Size
  send({0x02, 0x20, 0x00});              // LE Read Buffer Size V1
  send({0x0F, 0x20, 0x00});              // LE Read White List Size
  send({0x09, 0x10, 0x00});              // Read BD_ADDR (Controller end)
  assert(n == 14);
  printf("ok controller_init_sequence (%d events)\n", n);
}

static void test_le_advertising_report_shape() {
  uint8_t addr[6] = {0x01, 0x02, 0x03, 0x04, 0x05, 0x06};
  Packet data = {0x02, 0x01, 0x06};
  Packet e = SoftHci::make_le_advertising_report(addr, 0x00, static_cast<int8_t>(-50), data, 0x00);
  assert(e[0] == 0x3E);
  assert(e[2] == 0x02);  // subevent advertising report
  assert(e[3] == 0x01);  // num reports
  assert(e[4] == 0x00);  // event type
  assert(e[5] == 0x00);  // addr type
  assert(e[6] == 0x01 && e[11] == 0x06);
  assert(e[12] == 3);  // data len
  assert(e.back() == static_cast<uint8_t>(-50));
  printf("ok le_advertising_report_shape\n");
}

static void test_scan_enable_hook() {
  SoftHci hci;
  int enables = 0;
  int disables = 0;
  hci.set_event_sink([](const Packet&) {});
  hci.set_scan_enable_hook([&](bool en) {
    if (en)
      enables++;
    else
      disables++;
  });
  // LE Set Scan Enable enable=1 filter=0
  hci.handle_command({0x0C, 0x20, 0x02, 0x01, 0x00});
  assert(enables == 1);
  hci.handle_command({0x0C, 0x20, 0x02, 0x00, 0x00});
  assert(disables == 1);
  printf("ok scan_enable_hook\n");
}

static void test_inquiry_starts_bridge_and_eir_shape() {
  SoftHci hci;
  int enables = 0;
  std::vector<Packet> events;
  hci.set_event_sink([&](const Packet& e) { events.push_back(e); });
  hci.set_scan_enable_hook([&](bool en) {
    if (en) enables++;
  });
  // HCI Inquiry: LAP GIAC + length + num
  hci.handle_command({0x01, 0x04, 0x05, 0x33, 0x8B, 0x9E, 0x08, 0x00});
  assert(enables >= 1);
  assert(hci.inquiry_active());
  // Command Status event first
  assert(!events.empty());
  assert(events[0][0] == 0x0F);

  uint8_t addr[6] = {0x79, 0x90, 0x2B, 0x56, 0xAC, 0xD8};  // LE order of D8:AC:56:2B:90:79
  Packet eir = SoftHci::make_extended_inquiry_result(addr, -55, "Hue Lamp");
  assert(eir[0] == 0x2F);
  assert(eir[2] == 0x01);  // num responses
  // EIR name AD at offset after fixed fields: event hdr 2 + num1 + addr6 + psrm1 + res2 + cod3 + clk2 + rssi1 = 18
  // Actually: [0]=evt [1]=plen [2]=num [3..8]=addr [9]=psrm [10..11]=res [12..14]=cod [15..16]=clk [17]=rssi [18...]=eir
  assert(eir[18] > 0);
  assert(eir[19] == 0x09);  // Complete Local Name

  events.clear();
  // ADV_IND (0x00) → GD waits for SCAN_RESPONSE; Soft HCI must emit both.
  hci.inject_bridged_device(addr, 0x00, -55, Packet{0x02, 0x01, 0x06}, "Hue Lamp", 0x00);
  assert(events.size() == 2);
  assert(events[0][0] == 0x3E && events[0][2] == 0x02);
  assert(events[0][4] == 0x00);  // ADV_IND
  assert(events[1][0] == 0x3E && events[1][4] == 0x04);  // SCAN_RESPONSE
  events.clear();
  // NONCONN (0x03) stays single-report (not scannable).
  hci.inject_bridged_device(addr, 0x00, -55, Packet{0x02, 0x01, 0x06}, "Beacon", 0x03);
  assert(events.size() == 1);
  assert(events[0][4] == 0x03);
  events.clear();
  // Optional EIR for classic Settings list when explicitly requested.
  hci.inject_bridged_device(addr, 0x00, -55, Packet{0x02, 0x01, 0x06}, "Hue Lamp", 0x00, true);
  bool saw_le = false, saw_eir = false;
  int le_reports = 0;
  for (const auto& e : events) {
    if (e[0] == 0x3E) {
      saw_le = true;
      le_reports++;
    }
    if (e[0] == 0x2F) saw_eir = true;
  }
  assert(saw_le && saw_eir && le_reports == 2);
  printf("ok inquiry_and_eir_for_settings_pair_ui\n");
}

static void test_le_create_connection_emits_complete_not_status_only() {
  SoftHci hci;
  std::vector<Packet> events;
  hci.set_event_sink([&](const Packet& e) { events.push_back(e); });
  // LE Create Connection with peer AA:BB:CC:DD:EE:FF public (HCI LE order FF..AA)
  // scan_int=0x0010 scan_win=0x0010 filter=0 peer_type=0 peer=... own=0 intervals...
  Packet cmd = {
      0x0D, 0x20,  // opcode LE Create Connection
      25,          // plen
      0x10, 0x00, 0x10, 0x00, 0x00, 0x00,  // scan int/win, filter, peer_type public
      0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA,  // peer addr LE order
      0x00,                                // own addr type
      0x18, 0x00, 0x28, 0x00,              // conn interval min/max
      0x00, 0x00,                          // latency
      0x48, 0x00,                          // supervision
      0x00, 0x00, 0x00, 0x00               // CE len min/max
  };
  hci.handle_command(cmd);
  // Expect: Command Status (0x0F) + LE Connection Complete (0x3E sub 0x01)
  assert(events.size() >= 2);
  assert(events[0][0] == 0x0F);
  assert(events[0][2] == 0x00);  // status success on command
  bool saw_conn_complete = false;
  uint8_t conn_status = 0xFF;
  for (const auto& e : events) {
    if (e.size() >= 4 && e[0] == 0x3E && e[2] == 0x01) {
      saw_conn_complete = true;
      conn_status = e[3];
    }
  }
  assert(saw_conn_complete);
  // Without host hook: failed establish (not status-only half-open).
  assert(conn_status != 0x00);
  assert(!hci.le_create_pending());
  printf("ok le_create_connection_emits_complete status=0x%02x\n", conn_status);

  // Disconnection Complete shape (status + handle + reason)
  {
    Packet d = SoftHci::make_disconnection_complete(0x0040, 0x16, 0x00);
    assert(d.size() == 6);
    assert(d[0] == 0x05 && d[1] == 0x04 && d[2] == 0x00);
    assert(d[3] == 0x40 && d[4] == 0x00 && d[5] == 0x16);
    printf("ok disconnection_complete_packet handle=0x0040 reason=0x16\n");
  }
}

static void test_le_create_connection_hook_defers_complete() {
  SoftHci hci;
  std::vector<Packet> events;
  int hooks = 0;
  uint8_t got_type = 0xFF;
  hci.set_event_sink([&](const Packet& e) { events.push_back(e); });
  hci.set_le_create_connection_hook([&](const uint8_t addr[6], uint8_t t) {
    hooks++;
    got_type = t;
    // LE byte order of D8:AC:56:2B:90:79
    assert(addr[0] == 0x79 && addr[5] == 0xD8);
  });
  Packet cmd = {
      0x0D, 0x20, 25, 0x10, 0x00, 0x10, 0x00, 0x00, 0x01,  // random
      0x79, 0x90, 0x2B, 0x56, 0xAC, 0xD8, 0x00, 0x18, 0x00, 0x28, 0x00, 0x00, 0x00, 0x48, 0x00,
      0x00, 0x00, 0x00, 0x00};
  hci.handle_command(cmd);
  assert(hooks == 1);
  assert(got_type == 0x01);
  assert(hci.le_create_pending());
  // Only Command Status so far — no Connection Complete until inject.
  assert(events.size() == 1);
  assert(events[0][0] == 0x0F);
  uint8_t peer[6] = {0x79, 0x90, 0x2B, 0x56, 0xAC, 0xD8};
  hci.inject_le_connection_complete(0x3E, 0, 0, 0x01, peer);
  assert(!hci.le_create_pending());
  assert(events.size() == 2);
  assert(events[1][0] == 0x3E && events[1][2] == 0x01 && events[1][3] == 0x3E);
  printf("ok le_create_connection_hook_defers_complete\n");
}

static void test_le_connection_complete_packet_length() {
  uint8_t peer[6] = {0x01, 0x02, 0x03, 0x04, 0x05, 0x06};
  Packet e = SoftHci::make_le_connection_complete(0x3E, 0x0000, 0x00, 0x01, peer);
  // Event code + plen + parameters: size must equal 2 + Parameter_Total_Length
  assert(e[0] == 0x3E);
  assert(e[1] == 0x13);  // 19 parameter octets per Core Spec LE Connection Complete
  assert(e.size() == static_cast<size_t>(2 + e[1]));
  assert(e.size() == 21);
  assert(e[2] == 0x01);  // subevent
  assert(e[3] == 0x3E);  // status
  printf("ok le_connection_complete_packet_length size=%zu plen=0x%02x\n", e.size(), e[1]);
}

static void test_parse_le_create_connection_peer() {
  uint8_t params[25] = {};
  params[4] = 0x00;  // filter policy direct
  params[5] = 0x01;  // random
  params[6] = 0x01;
  params[7] = 0x02;
  params[8] = 0x03;
  params[9] = 0x04;
  params[10] = 0x05;
  params[11] = 0x06;
  uint8_t addr[6];
  uint8_t t = 0;
  uint8_t pol = 0xff;
  assert(SoftHci::parse_le_create_connection_peer(params, 25, addr, &t, &pol));
  assert(t == 0x01);
  assert(pol == 0x00);
  assert(addr[0] == 0x01 && addr[5] == 0x06);
  assert(!SoftHci::parse_le_create_connection_peer(params, 5, addr, &t));
  printf("ok parse_le_create_connection_peer\n");
}

static void test_accept_list_then_create_connection() {
  SoftHci hci;
  std::vector<Packet> events;
  hci.set_event_sink([&](const Packet& e) { events.push_back(e); });
  uint8_t got_peer[6] = {};
  uint8_t got_type = 0xff;
  bool hooked = false;
  hci.set_le_create_connection_hook([&](const uint8_t peer[6], uint8_t t) {
    hooked = true;
    got_type = t;
    std::memcpy(got_peer, peer, 6);
  });
  // LE Add Device To Filter Accept List: type=random, addr 3B:9B:7D:75:98:E5 in HCI LE order
  // (HCI LE order of E5:98:75:7D:9B:3B is 3B 9B 7D 75 98 E5)
  hci.handle_command({0x11, 0x20, 0x07, 0x01, 0x3B, 0x9B, 0x7D, 0x75, 0x98, 0xE5});
  // LE Create Connection with filter policy 0x01 and zero peer (as GD does)
  uint8_t create[28] = {
      0x0D, 0x20, 0x19,  // opcode + plen 25
      0x60, 0x00,        // scan int
      0x30, 0x00,        // scan win
      0x01,              // filter policy = accept list
      0x00,              // peer type ignored
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // peer addr zero
      0x00,              // own type
      0x18, 0x00, 0x28, 0x00, 0x00, 0x00, 0x48, 0x00, 0x00, 0x00, 0x00, 0x00,
  };
  events.clear();
  hci.handle_command(Packet(create, create + 28));
  assert(hooked);
  assert(got_type == 0x01);
  assert(got_peer[0] == 0x3B && got_peer[5] == 0xE5);
  printf("ok accept_list_then_create_connection\n");
}

static void test_bridge_encode_start_stop() {
  auto start = BridgeIpc::encode_start_le_scan(42, true);
  // request_id field present
  assert(start.size() > 4);
  assert(start[0] == 0x08);  // field1 varint
  auto stop = BridgeIpc::encode_stop_le_scan(7, 99);
  assert(stop.size() > 4);
  assert(stop[0] == 0x08);
  printf("ok bridge_encode_start_stop len_start=%zu len_stop=%zu\n", start.size(), stop.size());
}

static void test_bridge_parse_adv_report_roundtrip_fields() {
  // Hand-build Envelope { event { adv_report { address{address="AA:BB:CC:DD:EE:FF"}, rssi=-40, name="Hue" } } }
  // Using encode helpers only for outer structure via raw bytes.
  // address string
  const char* addr = "AA:BB:CC:DD:EE:FF";
  std::vector<uint8_t> bt_addr;
  // field1 string
  bt_addr.push_back(0x0a);
  bt_addr.push_back(static_cast<uint8_t>(std::strlen(addr)));
  bt_addr.insert(bt_addr.end(), addr, addr + std::strlen(addr));
  // field2 address_type=0 omitted

  std::vector<uint8_t> adv;
  // address = 2
  adv.push_back(0x12);
  adv.push_back(static_cast<uint8_t>(bt_addr.size()));
  adv.insert(adv.end(), bt_addr.begin(), bt_addr.end());
  // rssi = 3 as int32 -40 → varint of -40 as uint64
  {
    adv.push_back(0x18);
    // protobuf int32 -40 encoded as varint of uint64(-40)
    uint64_t v = static_cast<uint64_t>(static_cast<int64_t>(-40));
    while (v >= 0x80) {
      adv.push_back(static_cast<uint8_t>((v & 0x7f) | 0x80));
      v >>= 7;
    }
    adv.push_back(static_cast<uint8_t>(v));
  }
  // name = 4 "Hue"
  const char* name = "Hue";
  adv.push_back(0x22);
  adv.push_back(3);
  adv.insert(adv.end(), name, name + 3);

  std::vector<uint8_t> event;
  // adv_report = 2
  event.push_back(0x12);
  event.push_back(static_cast<uint8_t>(adv.size()));
  event.insert(event.end(), adv.begin(), adv.end());

  std::vector<uint8_t> env;
  // event = 4
  env.push_back(0x22);
  env.push_back(static_cast<uint8_t>(event.size()));
  env.insert(env.end(), event.begin(), event.end());

  BridgeAdv out;
  assert(BridgeIpc::parse_adv_report(env.data(), env.size(), &out));
  assert(out.address == "AA:BB:CC:DD:EE:FF");
  assert(out.name == "Hue");
  assert(out.rssi == -40);

  uint8_t le[6];
  assert(waydroid_bt::parse_bd_addr(out.address, le));
  // HCI LE order is reverse of display
  assert(le[0] == 0xFF && le[5] == 0xAA);

  auto payload = waydroid_bt::build_adv_payload(out);
  assert(!payload.empty());
  assert(payload[1] == 0x01);  // flags AD type

  SoftHci hci;
  Packet got;
  hci.set_event_sink([&](const Packet& e) { got = e; });
  hci.inject_le_advertising_report(le, 0, out.rssi, payload, 0x00);
  assert(got[0] == 0x3E);
  printf("ok bridge_parse_adv_report_and_inject\n");
}

static void test_proto_address_type_to_hci() {
  // Shipped mapping used by BluetoothHci::scanWorker before inject.
  assert(waydroid_bt::proto_address_type_to_hci(waydroid_bt::kProtoAddrPublic) ==
         waydroid_bt::kHciAddrPublic);  // 1 → 0x00
  assert(waydroid_bt::proto_address_type_to_hci(waydroid_bt::kProtoAddrRandom) ==
         waydroid_bt::kHciAddrRandom);  // 2 → 0x01
  assert(waydroid_bt::proto_address_type_to_hci(waydroid_bt::kProtoAddrUnspecified) ==
         waydroid_bt::kHciAddrPublic);
  assert(waydroid_bt::proto_address_type_to_hci(99) == waydroid_bt::kHciAddrPublic);

  // End-to-end: map then inject — HCI report must carry HCI Address_Type byte.
  SoftHci hci;
  Packet got;
  hci.set_event_sink([&](const Packet& e) { got = e; });
  uint8_t addr[6] = {0x01, 0x02, 0x03, 0x04, 0x05, 0x06};
  Packet data = {0x02, 0x01, 0x06};

  uint8_t hci_pub = waydroid_bt::proto_address_type_to_hci(waydroid_bt::kProtoAddrPublic);
  hci.inject_le_advertising_report(addr, hci_pub, -40, data, 0x00);
  // LE Meta: [0]=0x3E [1]=plen [2]=sub [3]=num [4]=evt [5]=addr_type
  assert(got.size() > 5);
  assert(got[5] == waydroid_bt::kHciAddrPublic);

  uint8_t hci_rnd = waydroid_bt::proto_address_type_to_hci(waydroid_bt::kProtoAddrRandom);
  hci.inject_le_advertising_report(addr, hci_rnd, -40, data, 0x00);
  assert(got[5] == waydroid_bt::kHciAddrRandom);

  // Bug regression: do NOT pass proto enum raw as HCI type
  assert(waydroid_bt::kProtoAddrPublic != waydroid_bt::kHciAddrPublic);
  assert(waydroid_bt::kProtoAddrRandom != waydroid_bt::kHciAddrRandom);
  printf("ok proto_address_type_to_hci PUBLIC→0x00 RANDOM→0x01\n");
}

static void test_parse_start_session_response() {
  // Response { error=0, start_le_scan { session_id=7 } }
  std::vector<uint8_t> sl;
  sl.push_back(0x08);  // session_id field1
  sl.push_back(0x07);
  std::vector<uint8_t> resp;
  resp.push_back(0x08);  // error=0
  resp.push_back(0x00);
  resp.push_back(0x6a);  // field 13 length-delimited
  resp.push_back(static_cast<uint8_t>(sl.size()));
  resp.insert(resp.end(), sl.begin(), sl.end());
  std::vector<uint8_t> env;
  env.push_back(0x08);  // request_id=1
  env.push_back(0x01);
  env.push_back(0x1a);  // response field3
  env.push_back(static_cast<uint8_t>(resp.size()));
  env.insert(env.end(), resp.begin(), resp.end());

  uint32_t sid = 0;
  assert(BridgeIpc::parse_start_le_scan_session(env.data(), env.size(), &sid));
  assert(sid == 7);
  printf("ok parse_start_session_response\n");
}

// Remote Name Request: Command Status + event 0x07 (not bare Command Complete).
// Just-Works: complete with Page Timeout + empty name (no SoftBT-Remote PIN bait).
static void test_remote_name_request_status_then_complete() {
  SoftHci hci;
  std::vector<Packet> events;
  hci.set_event_sink([&](const Packet& e) { events.push_back(e); });
  // opcode 0x0419, plen 10: BD_ADDR(6)+PSRM(1)+Reserved(1)+ClockOffset(2)
  Packet cmd = {0x19, 0x04, 0x0A, 0x79, 0x90, 0x2B, 0x56, 0xAC, 0xD8, 0x00, 0x00, 0x00, 0x00};
  hci.handle_command(cmd);
  assert(events.size() >= 2);
  assert(events[0][0] == 0x0F);  // Command Status
  assert(events[0][2] == 0x00);  // status success for the command itself
  assert(events[1][0] == 0x07);  // Remote Name Request Complete
  assert(events[1][1] == 0xFF);
  assert(events[1][2] == 0x04);  // Page Timeout — not success SoftBT-Remote
  // Name field (248 octets after status+addr) must be empty — no classic PIN name bait.
  bool name_nonzero = false;
  for (size_t i = 9; i < events[1].size(); i++) {
    if (events[1][i] != 0) {
      name_nonzero = true;
      break;
    }
  }
  assert(!name_nonzero);
  printf("ok remote_name_request_justworks_fail events=%zu status=0x%02x empty_name\n",
         events.size(), events[1][2]);
}

// Delete Stored Link Key (0x0c12): Command Complete must include Num_Keys_Deleted.
static void test_delete_stored_link_key_return_params() {
  SoftHci hci;
  std::vector<Packet> events;
  hci.set_event_sink([&](const Packet& e) { events.push_back(e); });
  // BD_ADDR (6) + Delete_All_Flag (1)
  Packet cmd = {0x12, 0x0C, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01};
  hci.handle_command(cmd);
  assert(!events.empty());
  // Event 0x0E Command Complete: plen, num_cmd, opcode_lo, opcode_hi, status, num_keys_lo, num_keys_hi
  const Packet& e = events.back();
  assert(e[0] == 0x0E);
  assert(e.size() >= 2 + e[1]);
  assert(e[3] == 0x12 && e[4] == 0x0C);  // opcode
  assert(e[5] == 0x00);                  // status
  assert(e[1] >= 6);                     // num_hci + opcode(2) + status + num_keys(2)
  assert(e.size() >= 8);
  assert(e[6] == 0x00 && e[7] == 0x00);  // Num_Keys_Deleted
  printf("ok delete_stored_link_key_return_params size=%zu plen=0x%02x\n", e.size(), e[1]);
}

// Status-only Command Complete: num_cmd(1)+opcode(2)+status(1) → plen=4, packet size=6.
// Guards against grafting multi-byte return bodies into the status-only fall-through group.
static void test_status_only_command_complete_shapes() {
  struct Case {
    const char* name;
    Packet cmd;
  };
  // Minimal valid HCI command packets (opcode LE + plen + params).
  const Case cases[] = {
      {"SetEventMask", {0x01, 0x0C, 0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}},
      {"WriteLeHostSupport", {0x6D, 0x0C, 0x02, 0x01, 0x00}},
      {"LeSetEventMask", {0x01, 0x20, 0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}},
      {"LeSetDefaultPhy", {0x31, 0x20, 0x03, 0x00, 0x01, 0x01}},
      {"WriteScanEnable", {0x1A, 0x0C, 0x01, 0x00}},
  };
  for (const auto& c : cases) {
    SoftHci hci;
    std::vector<Packet> events;
    hci.set_event_sink([&](const Packet& e) { events.push_back(e); });
    hci.handle_command(c.cmd);
    assert(!events.empty());
    const Packet& e = events.back();
    assert(e[0] == 0x0E);  // Command Complete
    assert(e[1] == 0x04);  // plen: num_cmd + opcode(2) + status
    assert(e.size() == 6);
    assert(e[5] == 0x00);  // status success
    printf("ok status_only_cc %s size=%zu plen=0x%02x\n", c.name, e.size(), e[1]);
  }
  printf("ok status_only_command_complete_shapes n=%zu\n",
         sizeof(cases) / sizeof(cases[0]));
}

// Host BlueZ property bits win; heuristics only when host_properties == 0.
static void test_resolve_char_properties_host_first() {
  const std::string fff4 = waydroid_bt::normalize_uuid("0000fff4-0000-1000-8000-00805f9b34fb");
  const std::string ordinary = waydroid_bt::normalize_uuid("00002a00-0000-1000-8000-00805f9b34fb");

  // Host reports notify → keep host mask, CCCD required.
  assert(waydroid_bt::resolve_char_properties(0x10, fff4) == 0x10);
  assert(waydroid_bt::char_needs_cccd(0x10));

  // Host reports read-only on a UUID that heuristics would notify: do NOT invent notify.
  assert(waydroid_bt::resolve_char_properties(0x02, fff4) == 0x02);
  assert(!waydroid_bt::char_needs_cccd(0x02));

  // Unknown host props (0) → heuristic may add notify for streaming UUID.
  const uint8_t guessed = waydroid_bt::resolve_char_properties(0, fff4);
  assert((guessed & waydroid_bt::kGattPropNotify) != 0);
  assert(waydroid_bt::char_needs_cccd(guessed));

  // Unknown props on ordinary name char → read only, no CCCD.
  const uint8_t name_props = waydroid_bt::resolve_char_properties(0, ordinary);
  assert(name_props == waydroid_bt::kGattPropRead);
  assert(!waydroid_bt::char_needs_cccd(name_props));

  printf("ok resolve_char_properties_host_first\n");
}

// Real SoftAttLink::build_from_uuids: host notify → CCCD present.
static void test_build_from_uuids_host_notify_gets_cccd() {
  SoftAttLink link;
  link.set_conn_handle(0x0040);
  link.set_peer("AA:BB:CC:DD:EE:10", 1);
  std::vector<std::pair<std::string, std::vector<SoftAttLink::CharSpec>>> tree = {
      {"0000fff0-0000-1000-8000-00805f9b34fb",
       {{"0000fff4-0000-1000-8000-00805f9b34fb", 0x10}}},
  };
  link.build_from_uuids(tree);
  assert(link.active());
  assert(link.has_cccd_for_char("0000fff4-0000-1000-8000-00805f9b34fb"));
  assert(link.char_props_for_uuid("0000fff4-0000-1000-8000-00805f9b34fb") == 0x10);
  printf("ok build_from_uuids_host_notify_gets_cccd attrs=%zu\n", link.attr_count());
}

// Host read-only must not grow a CCCD even for fff4-like UUID.
static void test_build_from_uuids_host_readonly_no_cccd() {
  SoftAttLink link;
  link.set_peer("AA:BB:CC:DD:EE:11", 1);
  std::vector<std::pair<std::string, std::vector<SoftAttLink::CharSpec>>> tree = {
      {"0000fff0-0000-1000-8000-00805f9b34fb",
       {{"0000fff4-0000-1000-8000-00805f9b34fb", 0x02}}},
  };
  link.build_from_uuids(tree);
  assert(link.active());
  assert(!link.has_cccd_for_char("0000fff4-0000-1000-8000-00805f9b34fb"));
  assert(link.char_props_for_uuid("0000fff4-0000-1000-8000-00805f9b34fb") == 0x02);
  printf("ok build_from_uuids_host_readonly_no_cccd\n");
}

// Zero host props → heuristic notify for known stream UUID → CCCD.
static void test_build_from_uuids_zero_props_heuristic_cccd() {
  SoftAttLink link;
  link.set_peer("AA:BB:CC:DD:EE:12", 1);
  std::vector<std::pair<std::string, std::vector<SoftAttLink::CharSpec>>> tree = {
      {"0000fff0-0000-1000-8000-00805f9b34fb",
       {{"0000fff4-0000-1000-8000-00805f9b34fb", 0}}},
  };
  link.build_from_uuids(tree);
  assert(link.has_cccd_for_char("fff4"));
  printf("ok build_from_uuids_zero_props_heuristic_cccd\n");
}

// Two Soft ATT links: building/activating second must not clear the first.
static void test_multi_link_soft_att_isolation() {
  SoftAttLink a;
  SoftAttLink b;
  a.set_conn_handle(0x0040);
  a.set_peer("AA:BB:CC:DD:EE:01", 1);
  a.build_from_uuids(
      {{"0000180f-0000-1000-8000-00805f9b34fb",
        {{"00002a19-0000-1000-8000-00805f9b34fb", 0x12}}}});
  assert(a.active());
  assert(a.conn_handle() == 0x0040);

  b.set_conn_handle(0x0041);
  b.set_peer("AA:BB:CC:DD:EE:02", 1);
  b.build_from_uuids(
      {{"0000fff0-0000-1000-8000-00805f9b34fb",
        {{"0000fff4-0000-1000-8000-00805f9b34fb", 0x10}}}});
  assert(b.active());
  assert(b.conn_handle() == 0x0041);

  // First link still alive and independent after second build.
  assert(a.active());
  assert(a.conn_handle() == 0x0040);
  assert(a.peer() == "AA:BB:CC:DD:EE:01");
  assert(a.has_cccd_for_char("2a19"));

  // Policy helper: different peers preserve each other.
  assert(waydroid_bt::multi_link_preserves_other_peer(a.peer(), b.peer()));
  assert(!waydroid_bt::multi_link_preserves_other_peer(a.peer(), a.peer()));

  // Reset B does not affect A.
  b.reset();
  assert(!b.active());
  assert(a.active());
  assert(a.conn_handle() == 0x0040);

  // Soft HCI Disconnection Complete is per-handle (not a broadcast teardown).
  Packet d0 = SoftHci::make_disconnection_complete(0x0040, 0x16, 0x00);
  Packet d1 = SoftHci::make_disconnection_complete(0x0041, 0x13, 0x00);
  assert(d0[3] == 0x40 && d0[4] == 0x00);
  assert(d1[3] == 0x41 && d1[4] == 0x00);
  assert(d0[5] == 0x16 && d1[5] == 0x13);

  printf("ok multi_link_soft_att_isolation\n");
}

// Notification parse extracts device id for multi-link filtering.
static void test_parse_gatt_notification_device_id() {
  // Minimal envelope: event(4) { gatt_notification(4) { device=1 "AA", char=2 "c", value=4 0x01 } }
  // Built with the same put helpers as BridgeIpc by hand.
  auto put_varint = [](std::vector<uint8_t>& o, uint64_t v) {
    while (v >= 0x80) {
      o.push_back(static_cast<uint8_t>((v & 0x7f) | 0x80));
      v >>= 7;
    }
    o.push_back(static_cast<uint8_t>(v));
  };
  auto put_key = [&](std::vector<uint8_t>& o, uint32_t field, uint32_t wire) {
    put_varint(o, (static_cast<uint64_t>(field) << 3) | wire);
  };
  auto put_str = [&](std::vector<uint8_t>& o, uint32_t field, const std::string& s) {
    put_key(o, field, 2);
    put_varint(o, s.size());
    o.insert(o.end(), s.begin(), s.end());
  };
  auto put_bytes = [&](std::vector<uint8_t>& o, uint32_t field, const std::vector<uint8_t>& b) {
    put_key(o, field, 2);
    put_varint(o, b.size());
    o.insert(o.end(), b.begin(), b.end());
  };

  std::vector<uint8_t> gn;
  put_str(gn, 1, "AA:BB:CC:DD:EE:01");
  put_str(gn, 2, "0000fff4-0000-1000-8000-00805f9b34fb");
  put_bytes(gn, 4, {0x01, 0x02});

  std::vector<uint8_t> ev;
  put_key(ev, 4, 2);
  put_varint(ev, gn.size());
  ev.insert(ev.end(), gn.begin(), gn.end());

  std::vector<uint8_t> env;
  put_key(env, 4, 2);
  put_varint(env, ev.size());
  env.insert(env.end(), ev.begin(), ev.end());

  std::string cu, dev;
  std::vector<uint8_t> val;
  assert(BridgeIpc::parse_gatt_notification(env.data(), env.size(), &cu, &val, &dev));
  assert(dev == "AA:BB:CC:DD:EE:01");
  assert(cu.find("fff4") != std::string::npos);
  assert(val.size() == 2 && val[0] == 0x01 && val[1] == 0x02);
  printf("ok parse_gatt_notification_device_id\n");
}

// Host ok_response omits Response.error when it is 0 (proto3 default). Soft HCI
// must treat that as success — otherwise set_notify always logs ok=0.
static void test_parse_response_ok_missing_error_field() {
  auto put_varint = [](std::vector<uint8_t>& o, uint64_t v) {
    while (v >= 0x80) {
      o.push_back(static_cast<uint8_t>((v & 0x7f) | 0x80));
      v >>= 7;
    }
    o.push_back(static_cast<uint8_t>(v));
  };
  auto put_key = [&](std::vector<uint8_t>& o, uint32_t field, uint32_t wire) {
    put_varint(o, (static_cast<uint64_t>(field) << 3) | wire);
  };
  auto put_sub = [&](std::vector<uint8_t>& o, uint32_t field, const std::vector<uint8_t>& body) {
    put_key(o, field, 2);
    put_varint(o, body.size());
    o.insert(o.end(), body.begin(), body.end());
  };

  // Response with only empty gatt_set_notify result (field 20), no error field.
  std::vector<uint8_t> gsn;  // empty GattSetNotifyResponse
  std::vector<uint8_t> resp;
  put_sub(resp, 20, gsn);
  std::vector<uint8_t> env;
  put_key(env, 1, 0);
  put_varint(env, 42);  // request_id
  put_sub(env, 3, resp);
  assert(BridgeIpc::parse_response_ok(env.data(), env.size()));

  // Explicit error=0 must still be OK.
  std::vector<uint8_t> resp0;
  put_key(resp0, 1, 0);
  put_varint(resp0, 0);
  put_sub(resp0, 20, gsn);
  env.clear();
  put_sub(env, 3, resp0);
  assert(BridgeIpc::parse_response_ok(env.data(), env.size()));

  // Explicit non-zero error is failure.
  std::vector<uint8_t> resp_err;
  put_key(resp_err, 1, 0);
  put_varint(resp_err, 5);
  env.clear();
  put_sub(env, 3, resp_err);
  assert(!BridgeIpc::parse_response_ok(env.data(), env.size()));

  printf("ok parse_response_ok_missing_error_field\n");
}

// A GattNotification that arrives while gatt_write waits for its Response must
// be queued and later returned by poll_gatt_notification (Tesla VCSEC replies
// to a write before the write completes). Previously it was silently dropped.
static void test_notification_during_write_is_queued() {
  auto put_varint = [](std::vector<uint8_t>& o, uint64_t v) {
    while (v >= 0x80) {
      o.push_back(static_cast<uint8_t>((v & 0x7f) | 0x80));
      v >>= 7;
    }
    o.push_back(static_cast<uint8_t>(v));
  };
  auto put_key = [&](std::vector<uint8_t>& o, uint32_t f, uint32_t w) {
    put_varint(o, (static_cast<uint64_t>(f) << 3) | w);
  };
  auto put_sub = [&](std::vector<uint8_t>& o, uint32_t f, const std::vector<uint8_t>& b) {
    put_key(o, f, 2);
    put_varint(o, b.size());
    o.insert(o.end(), b.begin(), b.end());
  };
  auto frame = [](const std::vector<uint8_t>& p) {
    std::vector<uint8_t> f = {static_cast<uint8_t>(p.size()), static_cast<uint8_t>(p.size() >> 8),
                              static_cast<uint8_t>(p.size() >> 16), static_cast<uint8_t>(p.size() >> 24)};
    f.insert(f.end(), p.begin(), p.end());
    return f;
  };
  std::vector<uint8_t> gn;
  put_sub(gn, 1, std::vector<uint8_t>{'C', 'A', 'R'});
  std::string cu = "00000213-b2d1-43f0-9b88-960cebf8b91e";
  put_sub(gn, 2, std::vector<uint8_t>(cu.begin(), cu.end()));
  std::vector<uint8_t> payload(91, 0x5a);
  put_sub(gn, 4, payload);
  std::vector<uint8_t> ev, notif;
  put_sub(ev, 4, gn);
  put_sub(notif, 4, ev);
  std::vector<uint8_t> resp, env;
  put_sub(resp, 10, {});
  put_key(env, 1, 0);
  put_varint(env, 100);
  put_sub(env, 3, resp);

  int sv[2];
  assert(::socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
  auto a = frame(notif), b = frame(env);
  assert(::write(sv[1], a.data(), a.size()) == static_cast<ssize_t>(a.size()));
  assert(::write(sv[1], b.data(), b.size()) == static_cast<ssize_t>(b.size()));
  BridgeIpc ipc;
  ipc.adopt_fd_for_test(sv[0]);
  assert(ipc.gatt_write_uuid("CAR", "00000212-b2d1-43f0-9b88-960cebf8b91e", "", {1, 2, 3}, false));
  assert(ipc.pending_notifications_for_test() == 1);
  std::string got_cu;
  std::vector<uint8_t> got;
  assert(ipc.poll_gatt_notification(&got_cu, &got, 10, "car"));
  assert(got_cu == cu && got.size() == 91);
  assert(ipc.pending_notifications_for_test() == 0);
  ::close(sv[1]);
  printf("ok notification_during_write_is_queued\n");
}


// Long write (Prepare 0x16 x2 + Execute 0x18) must reach the host as ONE write
// of the reassembled value (Tesla add-key 285 B at MTU 250 was dropped).
static void test_prepared_long_write_reassembled() {
  SoftAttLink link;
  link.set_conn_handle(0x0040);
  link.set_peer("AA:BB:CC:DD:EE:30", 1);
  link.build_from_uuids(
      {{"00000211-b2d1-43f0-9b88-960cebf8b91e",
        {{"00000212-b2d1-43f0-9b88-960cebf8b91e", 0x0c}}}});
  std::vector<uint8_t> written;
  int writes = 0;
  waydroid_bt::AttHostOps ops;
  ops.write_char = [&](const std::string& cu, const std::string&, const std::vector<uint8_t>& v,
                       bool) {
    if (cu.find("0212") == std::string::npos) return true;
    written = v;
    writes++;
    return true;
  };
  link.set_host_ops(ops);
  // Find value handle of 0212 via Read By Type? Use handle scan: try 0x0001..0x0020.
  uint16_t vh = 0;
  for (uint16_t h = 1; h < 0x40 && !vh; h++) {
    std::vector<Packet> out;
    auto emit = [&](const Packet& p) { out.push_back(p); };
    auto ev = [&](const Packet&) {};
    // Prepare Write probe at offset 0 with 1 byte; success response 0x17 means handle exists.
    Packet acl = {0x40, 0x20, 0, 0, 0, 0, 0x04, 0x00, 0x16,
                  static_cast<uint8_t>(h), static_cast<uint8_t>(h >> 8), 0, 0, 0xAA};
    acl[2] = static_cast<uint8_t>(acl.size() - 4);
    acl[4] = static_cast<uint8_t>(acl.size() - 8);
    link.on_acl_from_stack(acl, emit, ev);
    // Execute: only the 0212 value handle reaches write_char.
    int before = writes;
    Packet exec1 = {0x40, 0x20, 6, 0, 2, 0, 0x04, 0x00, 0x18, 0x01};
    link.on_acl_from_stack(exec1, emit, ev);
    if (writes > before) vh = h;
  }
  assert(vh != 0);
  writes = 0;
  std::vector<uint8_t> full(285);
  for (size_t i = 0; i < full.size(); i++) full[i] = static_cast<uint8_t>(i);
  std::vector<Packet> out;
  auto emit = [&](const Packet& p) { out.push_back(p); };
  auto ev = [&](const Packet&) {};
  for (size_t off = 0; off < full.size(); off += 245) {
    size_t n = std::min<size_t>(245, full.size() - off);
    Packet acl = {0x40, 0x20, 0, 0, 0, 0, 0x04, 0x00, 0x16, static_cast<uint8_t>(vh),
                  static_cast<uint8_t>(vh >> 8), static_cast<uint8_t>(off),
                  static_cast<uint8_t>(off >> 8)};
    acl.insert(acl.end(), full.begin() + off, full.begin() + off + n);
    uint16_t dl = static_cast<uint16_t>(acl.size() - 4), ll = static_cast<uint16_t>(acl.size() - 8);
    acl[2] = dl & 0xff; acl[3] = dl >> 8; acl[4] = ll & 0xff; acl[5] = ll >> 8;
    link.on_acl_from_stack(acl, emit, ev);
    assert(out.back()[8] == 0x17);
  }
  assert(writes == 0);
  Packet exec = {0x40, 0x20, 6, 0, 2, 0, 0x04, 0x00, 0x18, 0x01};
  link.on_acl_from_stack(exec, emit, ev);
  assert(out.back()[8] == 0x19);
  assert(writes == 1 && written == full);
  printf("ok prepared_long_write_reassembled len=%zu\n", written.size());
}

int main() {
  test_prepared_long_write_reassembled();
  test_notification_during_write_is_queued();
  test_opcode_of();
  test_command_complete_shape();
  test_reset_and_bd_addr();
  test_unknown_still_completes();
  test_extended_features_max_page_zero();
  test_le_rand_status_zero();
  test_read_remote_version_status_then_event();
  test_controller_init_sequence();
  test_le_advertising_report_shape();
  test_scan_enable_hook();
  test_inquiry_starts_bridge_and_eir_shape();
  test_bridge_encode_start_stop();
  test_bridge_parse_adv_report_roundtrip_fields();
  test_proto_address_type_to_hci();
  test_parse_start_session_response();
  test_parse_le_create_connection_peer();
  test_accept_list_then_create_connection();
  test_le_connection_complete_packet_length();
  test_le_create_connection_emits_complete_not_status_only();
  test_le_create_connection_hook_defers_complete();
  test_delete_stored_link_key_return_params();
  test_remote_name_request_status_then_complete();
  test_status_only_command_complete_shapes();
  test_resolve_char_properties_host_first();
  test_build_from_uuids_host_notify_gets_cccd();
  test_build_from_uuids_host_readonly_no_cccd();
  test_build_from_uuids_zero_props_heuristic_cccd();
  test_multi_link_soft_att_isolation();
  test_parse_gatt_notification_device_id();
  test_parse_response_ok_missing_error_field();
  printf("ALL_SOFT_HCI_TESTS_OK\n");
  return 0;
}
