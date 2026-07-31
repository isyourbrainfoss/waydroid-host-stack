# IPC protocol v1

## Transport

- Unix domain **stream** socket
- Host default: `/run/waydroid-bt/host.sock`
- Guest path: `/dev/socket/waydroid_bt` (LXC bind-mount)
- Frame: **4-byte little-endian length** + protobuf `Envelope`
- Max frame: 4 MiB

Schema: `protocol/proto/waydroid_bt/v1/messages.proto`  
Rust codec: crate `waydroid_bt_protocol`

## Envelope

| Field | Meaning |
|-------|---------|
| `request_id` | Correlates request/response; `0` for events |
| `request` / `response` / `event` | oneof body |

## Operations (v1)

| Op | Description |
|----|-------------|
| `Ping` | Protocol version + host version |
| `GetAdapterInfo` | Address, name, powered, LE flag, soft-disable |
| `SetPowered` | Guest power; soft-disable by default |
| `StartLeScan` / `StopLeScan` | Refcounted LE discovery sessions |
| `ConnectLe` / `Disconnect` | LE connection |
| `GattDiscover` / `GattRead` / `GattWrite` / `GattSetNotify` | GATT client |
| `CreateBond` / `RemoveBond` / `ListBonds` | Bonding via BlueZ |

## Events

| Event | When |
|-------|------|
| `AdapterStateEvent` | Soft power / adapter change |
| `AdvReportEvent` | Advertisement for a scan session |
| `ConnectionStateEvent` | Connect/disconnect |
| `GattNotificationEvent` | Notify/indicate value |
| `BondStateEvent` | Bond progress |
| `PairingRequestEvent` | Agent prompt (host-mediated) |

## Error codes

See `ErrorCode` in the proto. Notable: `SOFT_DISABLED` (guest off, host radio up), `BLUEZ`, `NOT_READY`, `UNSUPPORTED`.

## Versioning

- `PingResponse.protocol_major` / `protocol_minor`
- Current: **1.0**
- Breaking changes require major bump; additive fields are minor.

## Guest probe (on-device)

Binary: `waydroid-bt-guest-probe` (blocking Ping + GetAdapterInfo).

```sh
# On phone after Waydroid session is RUNNING:
sudo /usr/local/sbin/waydroid-bt-inject-socket.sh
sudo /usr/local/sbin/waydroid-guest-bt-probe.sh
# or:
sudo nsenter -t $(sudo lxc-info -P /var/lib/waydroid/lxc -n waydroid -pH) -m -- \
  /data/local/tmp/waydroid-bt/waydroid-bt-guest-probe --socket /run/waydroid-bt/host.sock
```

Success lines include `PING_OK`, `ADAPTER_OK powered=true`, and `PROBE_OK`.
