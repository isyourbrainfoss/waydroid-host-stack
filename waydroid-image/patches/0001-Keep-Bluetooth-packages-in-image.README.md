# Patch: keep Bluetooth packages in Waydroid image

## Problem

Waydroid vendor trees historically remove the Bluetooth app from the Bluetooth
APEX (e.g. `0001-hack-Remove-Bluetooth-app-from-apex.patch` under
`android_vendor_waydroid`). Result:

```
BluetoothManagerService: Fail to bind to: Intent { act=android.bluetooth.IBluetooth }
```

and `pm list packages` shows no Bluetooth package.

## Fix direction

1. **Revert / do not apply** the “Remove Bluetooth app from apex” hack for your
   chosen Waydroid Android version.
2. Ensure product packages still include Bluetooth stack modules.
3. Add feature files:

   ```
   android.hardware.bluetooth.xml
   android.hardware.bluetooth_le.xml
   ```

4. Ship the waydroid-bt guest backend and sepolicy from this repo’s `guest/`.

## Why not a single universal diff?

Hunk lines differ across Lineage 18/20/21 and Waydroid vendor revisions. Maintain
a per-version patch in your build manifest once the target lunch combo is pinned.

## Verification

```sh
waydroid shell pm list packages | grep -i bluetooth
waydroid shell logcat -d | grep BluetoothManagerService
```
