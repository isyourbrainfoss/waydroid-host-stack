# waydroid-bluetooth

**Share one Bluetooth radio between Linux and Waydroid** — so Android apps can use BLE GATT (scan, connect, notify) while the host keeps BlueZ as the only HCI owner.

Validated against typical sensor-style peripherals (pressure sensors, force gauges, scales) that speak standard **LE GATT**. Multi-device concurrent links are supported.

## Why this exists

Waydroid runs Android apps on Linux. Stock setups usually **cannot** use the phone/tablet’s Bluetooth the way native apps do:

- Passing the HCI device exclusively into Android **breaks** host Bluetooth.
- Running two stacks on one controller **fights** over L2CAP/ATT.

This project **does not passthrough HCI**. It bridges **capability**:

```
Android app (GATT)
       │
       ▼
Soft HCI HAL  (guest — fake controller + ATT for Fluoride)
       │  Unix socket (protobuf)
       ▼
waydroid-bt-host  (Linux — BlueZ client)
       │
       ▼
BlueZ + radio
```

| Layer | Role |
|-------|------|
| **BlueZ (host)** | Real radio, connections, encryption, bonds |
| **waydroid-bt-host** | D-Bus/BlueZ → length-prefixed protobuf IPC |
| **Socket mount** | Host socket visible inside Waydroid LXC |
| **Soft HCI HAL** | `IBluetoothHci` for Android; synthesizes HCI events; proxies GATT over IPC |
| **Android apps** | Use normal Bluetooth APIs (e.g. FlutterBluePlus) |

## What works (minimum GATT path)

- LE scan → advertising reports into Android  
- LE connect (multiple concurrent peers)  
- GATT service/characteristic discovery (synthetic handles in Soft ATT)  
- Read / write / write-without-response  
- Notifications / indications (host stream → Soft ATT HVN)  
- Host BlueZ remains usable (bluetoothctl, desktop tools)

## What is out of scope (for now)

- Classic Bluetooth profiles (A2DP, HFP, HID as first-class)  
- Full HCI passthrough  
- Perfect parity with OEM phone key / automotive stacks  
- Guaranteed Google Play certification / SafetyNet  

## Requirements

**Host**

- Linux with working **BlueZ** (`bluetoothd`) and a powered adapter  
- **Waydroid** with a running session  
- Rust toolchain (to build the host), or install a prebuilt binary you produce  
- Root for install, systemd (or run the host in the foreground), and LXC mount setup  

**Guest (Android in Waydroid)**

- Bluetooth packages present (some Waydroid images strip them — restore if needed)  
- Soft HCI HAL installed and selected as the Bluetooth HCI implementation  
- Socket path reachable (e.g. `/dev/socket/waydroid_bt` or `/run/waydroid-bt/host.sock` bind-mounted)

Works on **any distro** that can run Waydroid + BlueZ (desktop Linux, mobile Linux, etc.). Distro packages differ; the architecture does not.

## Quick start

### 1. Host: build and run the bridge

```sh
# deps: rustc/cargo, protoc, pkg-config, libdbus-1-dev (names vary by distro)
cargo build --release -p waydroid-bt-host

sudo install -Dm755 target/release/waydroid-bt-host /usr/local/bin/waydroid-bt-host
sudo install -Dm644 host/systemd/waydroid-bt-host.service \
  /etc/systemd/system/waydroid-bt-host.service
# edit unit paths if you install under /usr/local
sudo systemctl daemon-reload
sudo systemctl enable --now waydroid-bt-host
```

Default socket: `/run/waydroid-bt/host.sock` (create directory if needed; unit may handle this).

Smoke:

```sh
./scripts/smoke-host.sh
# or
waydroid-bt-ping --socket /run/waydroid-bt/host.sock --adapter
```

### 2. Mount the socket into Waydroid

```sh
# Example: install LXC mount fragment (adjust for your Waydroid layout)
sudo mkdir -p /etc/waydroid-bt
sudo cp lxc/waydroid-bt-mount.conf /etc/waydroid-bt/
# Apply via your distro’s Waydroid LXC config mechanism, or:
sudo ./scripts/waydroid-bt-inject-socket.sh   # runtime bind-mount helper
```

After Waydroid starts, re-inject if the container was recreated:

```sh
sudo ./scripts/waydroid-bt-session-hook.sh
```

### 3. Guest: Soft HCI HAL

Android’s stack must use this project’s **soft** `IBluetoothHci` instead of a missing/passthrough controller.

High level:

1. Cross-build `guest/hal` for `aarch64` (Android NDK + HIDL stubs; see `guest/hal/build_ndk.sh` and comments).  
2. Install into Waydroid overlay / rootfs:

   ```sh
   sudo ./scripts/waydroid-install-soft-hci-hal.sh /path/to/android.hardware.bluetooth@1.0-service.waydroid
   ```

3. Ensure init starts the HAL (`.rc` + wrapper script under `guest/hal/`).  
4. Restart Waydroid Bluetooth (or the session) so the stack binds Soft HCI.

If the image stripped Bluetooth apps/apex bits, restore them (see `scripts/waydroid-restore-bluetooth-apk.sh` and `docs/` notes). Some A13 images also need a **timerfd** JNI workaround (`scripts/waydroid-patch-bt-jni-timerfd.py`) so BLE bring-up does not hang.

### 4. Use an Android BLE app

Install any GATT client (sensor apps, nRF Connect, etc.). Scan, connect, enable notifications as usual.

Multiple devices can stay connected at once (Soft HCI assigns separate connection handles and host sessions).

## Repository layout

| Path | Contents |
|------|----------|
| `host/` | `waydroid-bt-host` — BlueZ bridge (Rust + bluer) |
| `protocol/` | Protobuf IPC v1 + Rust codec |
| `guest/hal/` | Soft HCI + Soft ATT + bridge IPC client (C++) |
| `guest-probe/` | CLI to exercise host IPC from the guest mount namespace |
| `lxc/` | Socket bind-mount fragment |
| `scripts/` | Install, inject, smoke, collect-logs |
| `docs/protocol.md` | Message reference |

## Architecture (short)

1. **Scan:** Soft HCI LE scan enable → host `StartLeScan` → BlueZ discovery → adv events → Soft HCI advertising reports.  
2. **Connect:** Soft HCI LE Create Connection → host `ConnectLe` + GATT discover → Soft ATT table from host UUIDs/properties → Connection Complete.  
3. **I/O:** Android ACL/ATT against Soft ATT; reads/writes/CCCD map to host GATT UUID ops.  
4. **Notify:** Host notification stream → Soft ATT Handle Value Notification → Android app.  
5. **Disconnect:** Per-handle teardown; other links stay up.

BlueZ owns the real link (including link-layer encryption after pairing). Soft HCI never drives the radio.

## Development

```sh
cargo test --workspace
# Soft HCI pure logic (host g++):
g++ -std=c++17 -O0 -I guest/hal \
  guest/hal/soft_hci.cpp guest/hal/soft_hci_test.cpp guest/hal/bridge_ipc.cpp \
  -o /tmp/soft_hci_test && /tmp/soft_hci_test
```

## Security / privacy

- Do not commit machine-specific paths, SSH keys, or Wi‑Fi credentials.  
- The host socket should be accessible only as needed by Waydroid (filesystem permissions / mount).  
- Pairing and bonds live in **BlueZ** on the host.

## Status

LE GATT multi-link is the supported path. Contributions that stay general (any BlueZ + Waydroid host) are preferred over device-specific hacks.

## License

MIT — see [LICENSE](LICENSE).
