# waydroid-host-stack

> **Note**
> This is very experimental. Assume nothing here is written, or necessarily read through or fully understood, by a human unless stated, and that includes this text. Use it at your own risk, but you're encouraged to reuse any parts you find useful. The human work here is mainly ideas, testing in reality, and persistence with a vision.


Host-owned **Bluetooth, GPS, and NFC** for [Waydroid](https://waydro.id/) on Linux phones (postmarketOS + Phosh).

Android apps get the *capability*. The Linux host keeps the radios: **BlueZ is the only HCI owner**. No exclusive passthrough, no second dongle.

## Field status

| Capability | What you get |
|------------|----------------|
| Soft HCI LE GATT | Real Android BLE path; Phone Key–class apps proven |
| Host GPS → guest | GeoClue / last-known → test providers (no Soft GNSS HAL) |
| Host NFC → guest | File + broadcast + `push`/fixture (live RF on OP6 unproven) |
| Classic A2DP / HCE | Out of scope |

**Shipped BT path:** Soft HCI HAL → Unix socket → `waydroid-bt-host` → BlueZ.  
**Cleanup (not shipped):** Strategy A (`IBluetooth` / `IBluetoothGatt` → same IPC).

## Install (on the phone)

Host bridge + root units (needs sudo; image-based hosts such as Nura/Duranium
are supported — see [docs/duranium.md](docs/duranium.md)):

```sh
sudo sh scripts/install-host-system.sh   # waydroid-bt-host, LXC include, root units
```

User-level helpers:

```sh
sh scripts/install-waydroid-stack.sh   # GPS + NFC + helpers; Soft HCI host is check-only
phone-key-ready                        # fail-closed Soft HCI + BlueZ
phone-field-ready --with-logs          # short field window (auto half-boot recover)
phone-idle
make check                             # desk: forwarder smoke + cargo test
```

Docs: [architecture](docs/architecture.md) · [phone-ready](docs/phone-ready.md) · [tesla-day-of](docs/tesla-day-of.md) · [GPS](docs/gps-forward.md) · [NFC](docs/nfc-forward.md) · [pmOS setup](docs/pmOS-setup.md) · [Duranium](docs/duranium.md)

## Layout

| Path | Role |
|------|------|
| `host/` | `waydroid-bt-host` (Rust + bluer) |
| `guest/hal/` | Soft HCI HAL |
| `protocol/` | Protobuf IPC v1 |
| `scripts/` | Forwarders, boot recovery, field pull |
| `tests/` | Desk selftests + golden Phone Key fixture |
| `docs/` | Architecture and day-of notes |
| `devices/` | Per-device config (fajita, enchilada, generic) |
| `packaging/systemd/` | Root units (LXC include, /run/xdg bind) |

```bash
cargo build --release -p waydroid-bt-host
cargo test --workspace
sh tests/smoke-forwards.sh
```

MIT. Design background: [`notes.md`](notes.md).
