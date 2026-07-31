# Setup guide (any Linux + Waydroid)

Straight checklist. Adjust package names for your distro.

## Host prerequisites

1. Bluetooth works on the host alone:

   ```sh
   bluetoothctl power on
   bluetoothctl scan on
   ```

2. Waydroid installs and a session can start:

   ```sh
   waydroid status
   # Session should be RUNNING for guest tests
   ```

3. Build tools: Rust stable, `protoc`, D-Bus development headers.

## Build host bridge

```sh
cargo build --release -p waydroid-bt-host
sudo install -Dm755 target/release/waydroid-bt-host /usr/local/bin/waydroid-bt-host
```

Run under systemd (`host/systemd/waydroid-bt-host.service`) or:

```sh
sudo mkdir -p /run/waydroid-bt
sudo waydroid-bt-host --socket /run/waydroid-bt/host.sock
```

## Socket into Waydroid

The guest Soft HCI must reach the host socket. Options:

1. **Runtime inject** (good for bring-up):

   ```sh
   sudo ./scripts/waydroid-bt-inject-socket.sh
   ```

2. **Persistent LXC mount**: install `lxc/waydroid-bt-mount.conf` into Waydroid’s LXC config (location varies by distro/version).

Confirm from host after session is up:

```sh
sudo ./scripts/waydroid-guest-bt-probe.sh
# Expect PING_OK / ADAPTER_OK / optional LE scan
```

## Soft HCI HAL (guest)

Android must load this HAL as `android.hardware.bluetooth@1.0-service`.

### Build (outline)

- NDK aarch64, C++17  
- HIDL-generated headers for `android.hardware.bluetooth@1.0`  
- Link against guest `libhidlbase`, `libutils`, etc. (from a Waydroid/Android rootfs or SDK)  
- Sources: `guest/hal/*.cpp`  

Exact flag sets depend on your NDK and rootfs; keep the resulting binary as:

`android.hardware.bluetooth@1.0-service.waydroid`

### Install

```sh
sudo ./scripts/waydroid-install-soft-hci-hal.sh ./android.hardware.bluetooth@1.0-service.waydroid
```

Ensure:

- `bluetooth-hci-waydroid` wrapper on PATH inside guest  
- `.rc` oneshot starts the HAL when the guest boots  
- Manifest registers the HIDL service  

Restart Waydroid session / enable Bluetooth in Android settings.

## Bluetooth packages inside Waydroid

If `pm list packages | grep -i bluetooth` is empty or Settings has no Bluetooth:

- Some Waydroid images **remove** Bluetooth APKs from the BT apex.  
- Use your distro’s restored image, or restore the APK into the apex/overlay (helper: `scripts/waydroid-restore-bluetooth-apk.sh`).

## Optional host-side patches

- **timerfd JNI hang** on some A13 stacks: `scripts/waydroid-patch-bt-jni-timerfd.py` (apply only if BLE never leaves turning-on).

## Verify GATT end-to-end

1. Host: `waydroid-bt-host` active, adapter powered.  
2. Guest: Soft HCI running (`logcat` / process list).  
3. Android: BLE app scans and sees a known peripheral.  
4. Connect, discover services, enable notify — values update.  
5. Connect a second peripheral without disconnecting the first.

## Collect logs

```sh
./scripts/collect-logs.sh
```

Sanitise output before sharing (no SSIDs/passwords/personal hostnames if you care).
