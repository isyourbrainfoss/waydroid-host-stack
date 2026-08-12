# Architecture

## Decision: Alternative E (refined)

Full guest Bluetooth **system** path + invisible host bridge to BlueZ.  
BlueZ is the **only** HCI owner on the phone.

### Rejected approaches

| Id | Approach | Why rejected for daily-driver Linux phone |
|----|----------|-------------------------------------------|
| A | Exclusive HCI / USB passthrough | Host loses Bluetooth |
| B | App-classpath `android.bluetooth` stubs | Forever incomplete; Settings/CDM/background break |
| C | Host-only (no Android BT) | Fails ultimate goal |
| D | Dual controllers | Awkward/impossible on phones |
| F | Virtual HCI as second master | Two host stacks fight the controller |

### HCI impedance mismatch

Stock Fluoride/Gabeldorsche expects `IBluetoothHci` and then runs **its own L2CAP/ATT**. BlueZ also owns L2CAP/ATT for connections it manages. Forwarding raw HCI into BlueZ while both run is broken.

**Sharing rule (unchanged):** ATT/L2CAP/HCI are owned **once** — by BlueZ. The guest never becomes a second HCI master and we do not bind `/dev/hci0` into LXC.

**Shipped field path (LE):** Soft HCI HAL (`IBluetoothHci`) in the guest synthesizes a virtual controller for Fluoride. Scan, LE create-connection, and GATT are intercepted and sent over the Unix socket to `waydroid-bt-host` → BlueZ. Tesla Phone Key is proven on this path. Soft HCI is **not** exclusive HCI passthrough and **not** a second radio owner.

**Cleanup north star (Strategy A):** map guest `IBluetooth` / `IBluetoothGatt` directly to the same BlueZ IPC so Settings / CompanionDeviceManager / background LE do not depend on covering every HCI opcode. Strategy A is **not** the current field stack; do not rip out Soft HCI until that binder backend exists and Phone Key still works.

### Components

```
┌─ Linux host ─────────────────────────────────────────────┐
│  bluetui / Phosh / PipeWire                              │
│           │                                              │
│           ▼                                              │
│        BlueZ (bluetoothd)  ◄── sole HCI + bond DB        │
│           ▲                                              │
│           │ D-Bus (bluer)                                │
│  waydroid-bt-host.service                                │
│           ▲                                              │
│  /run/waydroid-bt/host.sock                              │
└───────────│──────────────────────────────────────────────┘
            │ LXC bind-mount
┌───────────▼──────────────────────────────────────────────┐
│  Waydroid                                                │
│  /dev/socket/waydroid_bt                                 │
│           ▲                                              │
│  Soft HCI HAL (shipped) → BlueZ IPC (not chip HCI)       │
│           ▲                                              │
│  BluetoothManagerService / framework APIs                │
│           ▲                                              │
│  Apps                                                    │
└──────────────────────────────────────────────────────────┘
```

## Policy

| Concern | Rule |
|---------|------|
| Power on/off | Host BlueZ is truth. Guest “off” → **soft-disable** (guest sees off; radio stays up). `force_host` optional for explicit BlueZ power. |
| Address / privacy | One identity from BlueZ |
| Bonds | Stored in BlueZ |
| Discovery | Refcounted sessions (host UI + guest) |
| Kill Waydroid | Host BT unaffected; sessions cleared |
| Kill BlueZ | Guest sees adapter unavailable |

## ADR-001: Guest integration

**Status:** Field default is Soft HCI. Strategy A remains the cleanup north star.

| Layer | What we run today | North star |
|-------|-------------------|------------|
| Guest stack | Restored Fluoride / Gabeldorsche | Unchanged |
| Vendor HAL | Soft HCI (`IBluetoothHci`) → host socket | Strategy A: `IBluetooth` / `IBluetoothGatt` → same socket |
| Host | `waydroid-bt-host` + BlueZ (sole HCI + ATT) | Unchanged |
| Classic audio | Out of scope (A2DP/HFP + PipeWire) | Still out of scope |

**Shipped:** Soft HCI LE GATT (multi-link), Phone Key proven. High-level scan/connect/GATT still go to BlueZ; the Soft HCI layer is a virtual controller, not a second chip master.

**Cleanup (Strategy A):** BlueZ-backed Bluetooth **system service backend** over the host socket so Settings/CDM/background LE do not require every HCI opcode. Do not replace Soft HCI in this tree until that backend is proven on-device.

**Still rejected:** exclusive HCI / USB passthrough (host loses BT); app-classpath stubs; dual controllers; forwarding raw HCI into BlueZ while Fluoride also runs ATT.

## Protocol

See [protocol.md](protocol.md). Version **1.0**, LE-first.
