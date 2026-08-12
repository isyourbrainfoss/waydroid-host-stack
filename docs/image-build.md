# Custom Waydroid image (Bluetooth restored)

Stock Waydroid vendor trees remove the Bluetooth app from the Bluetooth APEX (see community discussion on [waydroid/waydroid#155](https://github.com/waydroid/waydroid/issues/155)). Without restoring packages, `BluetoothManagerService` cannot bind `IBluetooth`.

## What this repo provides

| Path | Purpose |
|------|---------|
| `waydroid-image/patches/` | Patch series to stop stripping BT + enable features |
| `waydroid-image/scripts/build-image.sh` | Helper outline for AG/Lineage-based builds |
| `guest/` | Backend binary stubs, sepolicy, init for image integration |

## High-level steps

1. Set up a Waydroid/Lineage build environment ([Waydroid docs](https://docs.waydro.id/development/compile-waydroid-lineage-os-based-images)).
2. Apply patches from `waydroid-image/patches/` onto the matching `android_vendor_waydroid` / product tree revision.
3. Include guest backend (`guest/hal`) in the product packages / vendor image.
4. Add sepolicy from `guest/sepolicy`.
5. Build `system.img` / `vendor.img` for your arch (`arm64` on phones).
6. Install images into Waydroid on the phone (`waydroid init` / image replace per distro docs).

## Patch intent

1. **Do not remove** `Bluetooth` from the Bluetooth APEX / product packages.
2. Set system features:
   - `android.hardware.bluetooth`
   - `android.hardware.bluetooth_le`
3. Install `waydroid_bt` backend + init that opens `/dev/socket/waydroid_bt`.
4. SELinux: allow Bluetooth process to connect to the host bridge socket.

Exact patch hunks depend on the Waydroid Android version (11/13/…). Pin one generation and refresh patches when upgrading.

## Verify inside guest

```sh
waydroid shell
# then:
pm list packages | grep -i bluetooth
getprop | grep bluetooth
logcat -d | grep -i BluetoothManagerService
ls -l /dev/socket/waydroid_bt
```

Expect: Bluetooth packages present; no permanent `Fail to bind to: Intent { act=android.bluetooth.IBluetooth }` once the backend is running.
