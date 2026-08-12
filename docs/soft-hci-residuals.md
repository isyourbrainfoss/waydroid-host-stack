# Soft HCI residuals (known, non-blocking for Phone Key)

Status as of field success (Model Y Phone Key unlock via Soft HCI).

Soft HCI is the **shipped field LE path**. Strategy A (binder `IBluetooth` /
`IBluetoothGatt` → BlueZ IPC) is cleanup, not what fajita runs today.

## Proven

- Multi-link LE GATT through host BlueZ + guest Soft HCI HAL.
- Tesla VCSEC whitelist + unlock over BLE (see field session logs).
- `cargo test --workspace` green on desk builds.

## Residual / not full product polish

| Area | Note |
|------|------|
| Scan/connect fd paths | Some residual unlocked paths noted in earlier review; not the Phone Key failure mode |
| Classic audio dual-stack | Out of scope (A2DP/HFP + PipeWire) |
| Background LE power policy | Host + Waydroid left armed drains battery; use phone-ready checklist |
| Guest NFC service | No Soft NFC HAL; use host NFC forwarder instead |

## Re-check on change

```bash
cargo test --workspace
# On device after HAL deploy: dumpsys bluetooth_manager, guest probe PING_OK
```
