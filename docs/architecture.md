# Architecture

## Problem

Android (inside Waydroid) and Linux both want Bluetooth. One physical controller cannot sanely be mastered by two full stacks (Fluoride + BlueZ) at once.

## Decision

**BlueZ is the sole HCI owner.** Waydroid never receives raw HCI for the real radio.

Capability is exported through a **high-level IPC** plus a **Soft HCI** adapter that satisfies Android’s Bluetooth HAL contract.

## Components

```
┌─ Linux host ─────────────────────────────────────────┐
│  Desktop BT tools / system apps                      │
│           │                                          │
│           ▼                                          │
│        BlueZ (bluetoothd)  ◄── only HCI + bonds      │
│           ▲                                          │
│           │ D-Bus (bluer)                            │
│  waydroid-bt-host                                    │
│           ▲                                          │
│  Unix socket (e.g. /run/waydroid-bt/host.sock)       │
└───────────│──────────────────────────────────────────┘
            │ LXC bind-mount
┌───────────▼──────────────────────────────────────────┐
│  Waydroid                                            │
│  Soft HCI HAL  (IBluetoothHci)                       │
│    • LE scan / connect HCI events                    │
│    • Soft ATT (per-connection GATT tables)           │
│    • bridge_ipc → host protobuf                      │
│           ▲                                          │
│  Android Bluetooth stack + apps                      │
└──────────────────────────────────────────────────────┘
```

## Soft HCI

Implements enough HCI commands/events for Android BLE bring-up and LE links:

- Controller info / LE feature bits  
- Scan enable → host discovery  
- LE Create Connection → host connect + GATT discover  
- ACL carrying ATT for Soft ATT  
- Disconnect complete per handle  

It does **not** implement a second radio stack.

## Soft ATT

For each concurrent LE peer:

- Stable HCI **connection handle**  
- Synthetic GATT attribute table (handles local to Soft ATT)  
- Properties from host discovery when available; UUID heuristics as fallback  
- CCCD writes → host `set_notify`  
- Host notification bytes → Handle Value Notification  

Multi-link: connecting device B does **not** tear down device A.

## Host service

`waydroid-bt-host`:

- Listens on a Unix stream socket  
- Frames: 4-byte little-endian length + protobuf `Envelope`  
- Ops: adapter info, LE scan, connect, disconnect, GATT discover/read/write/notify, bonds (as implemented)  
- Events: adv reports, connection state, GATT notifications  

See [protocol.md](protocol.md) and `protocol/proto/`.

## Failure modes to expect

| Symptom | Typical cause |
|---------|----------------|
| No adapters in guest | Soft HCI not running / stack not bound |
| Scan empty | Host socket missing, discovery blocked, or scan hold too short |
| Connect 133 / timeout | Host connect failed, residual handle without disconnect complete, or image BT broken |
| Connected but no notify | CCCD not wired, host notify stream dead, or wrong characteristic properties |
| Host BT dies when guest starts | Accidental HCI passthrough / wrong HAL — not this design |

## Future directions (not required for basic GATT)

- ATT PDU proxy for odd GATT layouts  
- L2CAP CoC byte streams for non-GATT LE protocols  
- Richer bonding UX  
- Distro packages for host + mount  
