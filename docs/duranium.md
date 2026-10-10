# Image-based hosts (Nura "Duranium", OnePlus 6 / enchilada)

Duranium is an image-based Nura (postmarketOS-derived) system:

| Path | State |
|---|---|
| `/usr` (incl. `/usr/local`, `/opt`) | read-only erofs + sysext overlay |
| `/etc` | confext overlay, writable as root (upper in `/var/lib/extensions.mutable/etc`), **noexec** |
| `/var`, `/` | writable ext4 |
| `/var/lib/extensions`, `/var/lib/confexts` | sysext / confext images |
| `apk` | empty database — packages cannot be added |
| host tools | `lxc-*` present; no `nsenter`, `python3`, `cargo`, `gcc` |

The stack therefore installs into `/var/lib/waydroid-host-stack` and
`/etc/systemd/system`, never shells out to python3/nsenter on the host, and
uses root systemd units instead of `sudo -n` from user hooks.

## Verified baseline (2026-10)

- OnePlus 6 (`oneplus-enchilada`), kernel 7.1 sdm845, BlueZ 5.87, `hci_uart_qca`
- Waydroid 1.6.3, Lineage 20.0 VANILLA, fingerprint
  `waydroid/lineage_waydroid_arm64/waydroid_arm64:13/TQ3A.230901.001`
  → the TQ3A Bluetooth APK restore + JNI patch path applies.

## Build (desk)

```sh
rustup target add aarch64-unknown-linux-musl
cargo install cargo-zigbuild && pip install ziglang
cargo zigbuild --release --target aarch64-unknown-linux-musl \
  -p waydroid-bt-host -p waydroid-bt-guest-probe --features waydroid-bt-host/vendored-dbus
# static binaries in target/aarch64-unknown-linux-musl/release/
```

`vendored-dbus` statically links libdbus so nothing extra is needed on the phone.

## Install (phone)

```sh
# no root
sh scripts/install-host-system.sh --print-paths
sh scripts/install-host-system.sh --dry-run
# root
sudo sh scripts/install-duranium.sh            # = FORCE_IMMUTABLE=1 install-host-system.sh
# restart Waydroid so the LXC include takes effect
waydroid session stop
sudo systemctl restart waydroid-container
waydroid session start
```

Optional sysext instead of `/var/lib/waydroid-host-stack`:

```sh
sh scripts/build-sysext.sh                    # out/waydroid-host-stack.raw (or dir)
sudo sh scripts/install-host-system.sh --sysext out/waydroid-host-stack.raw
```

Unsigned extensions are rejected if the image enforces a signed sysext image
policy; use the default install in that case. A sysext pinned with
`--id/--level` must be rebuilt after every OTA.

## Android side (Lineage 20 / TQ3A only)

```sh
sudo $SBINDIR/waydroid-restore-bluetooth-apk.sh Bluetooth.apk libbluetooth_jni.so
sudo $SBINDIR/waydroid-bt-stabilize-adapter.sh
```

Both refuse to run unless `system.img` reports SDK 33 / build id `TQ3A*`.

## NFC

`nfc0` (nxp_nci_i2c) exists, but neard is not in the image and cannot be
apk-installed. The NFC installer reports this and keeps push/fixture/last-tag
delivery; live tags need neard from the image or a sysext.
