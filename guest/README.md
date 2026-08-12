# Guest (Waydroid) Bluetooth backend

This directory is integrated into a **custom Waydroid/Lineage image**.

## Layout

| Path | Role |
|------|------|
| `hal/` | **Shipped** Soft HCI HAL (`IBluetoothHci`) + host-bridge IPC client |
| `sepolicy/` | SELinux rules for the bridge socket |
| `init/` | `init.rc` snippet to wait on socket and start helper |

## Integration strategy (ADR-001)

**Shipped field path:** Soft HCI HAL in `hal/` — Fluoride talks `IBluetoothHci` to a virtual controller; scan / LE connect / GATT are bridged to host BlueZ over `/dev/socket/waydroid_bt` (or `/run/waydroid-bt/host.sock`). BlueZ is the only ATT/HCI owner. Phone Key uses this path.

**Cleanup north star (Strategy A):** a BlueZ-backed `IBluetooth` / `IBluetoothGatt` system service backend on the same socket, so Settings/CDM/background LE do not depend on covering every HCI opcode. **Not the current field stack** — do not remove Soft HCI until that backend exists and Phone Key still works.

Not: exclusive HCI passthrough.  
Not: app-classpath stubs of `android.bluetooth.*`.  
Not: a second HCI master on the chip.

### Phased guest work

1. **Soft HCI (done / field)** — virtual controller + BlueZ IPC; LE GATT multi-link.
2. **Strategy A (cleanup)** — implement/patch `IBluetooth` / `IBluetoothGatt` enough for Settings/CDM.
3. **Full LE polish** — bonds/privacy aligned with host protocol v1 without opcode-by-opcode HCI growth.

## Socket

| Side | Path |
|------|------|
| Host | `/run/waydroid-bt/host.sock` |
| Guest | `/run/waydroid-bt/host.sock` (dir bind) + optional `/dev/socket/waydroid_bt` symlink |

## Guest IPC probe (proven on fajita)

Use the host-built musl binary + inject scripts (not the C connectivity stub):

| Artifact | Role |
|----------|------|
| `host/src/bin/waydroid-bt-guest-probe.rs` | Blocking Ping + GetAdapterInfo client |
| `scripts/waydroid-bt-inject-socket.sh` | Bind-mount `/run/waydroid-bt` into LXC |
| `scripts/waydroid-guest-bt-probe.sh` | Stage binary into guest + `nsenter -m` run |

```sh
sudo /usr/local/sbin/waydroid-bt-inject-socket.sh
sudo /usr/local/sbin/waydroid-guest-bt-probe.sh
# → PING_OK / ADAPTER_OK powered=true / PROBE_OK
```

## Build note

The **Soft HCI HAL** (`hal/BluetoothHci.*`, `soft_hci.*`) is the shipped guest integration.  
`hal/waydroid_bt_client.c` is a connectivity-only stub; prefer `waydroid-bt-guest-probe` for protocol ping proof.  
A full AOSP/NDK `IBluetooth` / `IBluetoothGatt` backend (Strategy A) is cleanup, not the field stack.
