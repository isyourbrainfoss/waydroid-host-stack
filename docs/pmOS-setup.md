# postmarketOS setup

Target: Linux phone with **postmarketOS**, **Phosh**, **BlueZ**, **Waydroid**.

## Phase 0 — Host baseline

1. Install Bluetooth stack and UI tools:

   ```sh
   sudo apk add bluez bluez-openrc  # or systemd bluez unit on systemd images
   # optional UI
   sudo apk add bluetui  # if packaged; else use bluetoothctl
   ```

2. Power on adapter:

   ```sh
   bluetoothctl power on
   bluetoothctl show
   ```

3. Confirm multi-client: keep `bluetoothctl scan on` in one terminal and use bluetui or a second client; both should work.

4. Record device codename, kernel, and BlueZ version for bug reports:

   ```sh
   cat /etc/os-release
   uname -a
   bluetoothctl --version
   ```

## Install waydroid-bt-host

Image-based hosts (Nura "Duranium", anything with a read-only `/usr`): see
[duranium.md](duranium.md). Summary of the generic installer:

```sh
# Build (desk, cross): static aarch64 musl binaries, no libdbus needed on the phone
cargo zigbuild --release --target aarch64-unknown-linux-musl \
  -p waydroid-bt-host -p waydroid-bt-guest-probe --features waydroid-bt-host/vendored-dbus
# or natively on a mutable pmOS phone:
cargo build --release -p waydroid-bt-host -p waydroid-bt-guest-probe

sudo sh scripts/install-host-system.sh            # auto-detects layout
sh scripts/install-host-system.sh --print-paths   # show where things go
```

Install layout (`scripts/lib/paths.sh`, override with env `PREFIX`, `BINDIR`,
`SBINDIR`, `LIBEXECDIR`, `UNITDIR`, `SYSCONFDIR`, `FORCE_IMMUTABLE=1|0`):

| | mutable host | image-based host |
|---|---|---|
| `PREFIX` | `/usr/local` | `/var/lib/waydroid-host-stack` |
| `BINDIR` | `$PREFIX/bin` | `$PREFIX/bin` |
| `SBINDIR` (root helpers) | `$PREFIX/sbin` | `$PREFIX/sbin` |
| `LIBEXECDIR` (guest probe) | `$PREFIX/libexec` | `$PREFIX/libexec` |
| `UNITDIR` | `/etc/systemd/system` | `/etc/systemd/system` |
| `SYSCONFDIR` | `/etc/waydroid-bt` | `/etc/waydroid-bt` |

Or build a systemd-sysext (`sh scripts/build-sysext.sh`, then
`sudo sh scripts/install-host-system.sh --sysext out/waydroid-host-stack.raw`).
Distro packages (`packaging/postmarketos/`) keep `/usr/bin` + `/usr/lib/systemd/system`.

Root units installed:

| Unit | Role |
|---|---|
| `waydroid-bt-host.service` | BlueZ bridge, socket `/run/waydroid-bt/host.sock` |
| `waydroid-bt-lxc-include.path/.service` | re-adds `lxc.include` when Waydroid rewrites its LXC config |
| `waydroid-container.service.d/50-waydroid-bt.conf` | `ExecStartPre`: mkdir socket dir + re-apply include before every container start |
| `waydroid-bt-inject.timer/.service` | runtime fallback bind if the guest lost the socket |
| `waydroid-run-xdg.path/.service` | binds `/run/user/<uid>` → `/run/xdg` (replaces `sudo -n` in user hooks) |

## LXC socket mount

Host and guest use the **same path**: host `/run/waydroid-bt/host.sock` →
guest `/run/waydroid-bt/host.sock` (directory rbind). `/dev/socket/waydroid_bt`
is only an optional convenience symlink created by the inject script.

The fragment `lxc/waydroid-bt-mount.conf` is installed to
`/etc/waydroid-bt/lxc-mount.conf` and referenced by one line at the **end** of
`/var/lib/waydroid/lxc/waydroid/config`:

```
lxc.include = /etc/waydroid-bt/lxc-mount.conf
```

It must come after the `config_nodes` include (which mounts a tmpfs on `/run`).
Do **not** append to `config_nodes`: Waydroid regenerates it. The include is
re-applied automatically (path unit + container `ExecStartPre`), so it survives
`waydroid init` and Waydroid upgrades.

## Custom Waydroid image

Stock images **strip Bluetooth packages**. Build a custom image with patches from `waydroid-image/` — see [image-build.md](image-build.md).

## Smoke tests

```sh
./scripts/smoke-host.sh
./scripts/smoke-guest.sh   # after Waydroid + guest backend
./scripts/collect-logs.sh
```

## Acceptance checklist (Phase 2)

- [ ] Host bluetui/bluetoothctl works with Waydroid running
- [ ] Guest Settings shows BT with host adapter address
- [ ] Guest LE scan sees a known peripheral
- [ ] GATT read/notify works
- [ ] Bond appears in BlueZ (`bluetoothctl devices Paired`)
- [ ] Stop Waydroid → host BT still works
- [ ] Stop `bluetooth.service` → guest reports BT unavailable

## Device-specific notes

Per-device settings live in `devices/<codename>.conf` (firmware list, NFC,
half-boot fix, package manager). `scripts/setup-pmos.sh` auto-detects the
device (`IMAGE_ID`, `/etc/deviceinfo`, device-tree) — override `WHS_DEVICE=`.
Shipped: `oneplus-fajita`, `oneplus-enchilada`, `generic`.

### OnePlus 6T (`oneplus-fajita`) — working baseline

| Field | Value |
|-------|-------|
| Codename | `oneplus-fajita` |
| SoC / BT | SDM845 / WCN3990 (HCI UART QCA) |
| pmOS channel | edge, systemd + Phosh |
| Waydroid | 1.6.3 (package install) |
| Notes | See firmware section below |

**Bluetooth firmware (required):**

1. Package `firmware-oneplus-sdm845` must provide:
   - `/lib/firmware/postmarketos/qca/crbtfw21.tlv` (kernel searches `postmarketos/` first)
   - `/lib/firmware/qca/OnePlus/enchilada/crnv21.bin` (NVM; shared OP6/OP6T path)
2. Optional: `linux-firmware-qca` supplies generic `qca/crbtfw21.tlv` but the **postmarketos** copy is different and preferred.
3. If `bluetoothctl` shows no controller while `hciconfig` shows `hci0` with address `00:00:00:00:5A:AD`, firmware did not load correctly.
4. **Do not** unbind `hci_uart_qca` sysfs to reload — can oops the kernel (`qca_power_off`). Prefer reboot (or avoid reload).

**Encryption / remote work:**

- Full-disk encryption (unl0kr) blocks remote recovery after reboot: the machine cannot enter a passphrase for you.
- For experiment phones used over SSH, prefer **unencrypted** installs (`pmbootstrap install` **without** `--fde`).
- Converting encrypted → unencrypted means **reinstall/reflash root**, not a config toggle.

### Lab status (2026-07-27) — unencrypted BPO + host bridge + Waydroid

| Item | Status |
|------|--------|
| Install | Official BPO **edge/phosh** image (no FDE); userdata + boot flash only |
| SSH | LAN user account; set `FAJITA_HOST` / your own key (do not commit host IPs) |
| Host BlueZ | Working (`OnePlus 6T`, powered) |
| `waydroid-bt-host` | systemd **active**, Ping/GetAdapterInfo OK |
| Waydroid | init VANILLA Lineage 20 / Android **13** (`waydroid_arm64`) |
| Session | **RUNNING** (start: `waydroid session start` on Phosh user) |
| Guest BT packages | **`pm path` GREEN** — `package:/apex/com.android.btservices/app/Bluetooth@TQ3A.230901.001/Bluetooth.apk` |
| Guest feature flag | `android.hardware.bluetooth` present |
| Guest manager | **IBluetooth bound** after timerfd patch + long BLE start timeout; state may stay `BLE_TURNING_ON` until HCI HAL/bridge |
| Socket into guest | **Proven:** bind-mount `/run/waydroid-bt` into LXC + `waydroid-bt-guest-probe` via `nsenter -m` |
| Guest IPC breakthrough | **Ping + GetAdapterInfo + LE scan** from guest mount NS; host BlueZ stays up |
| LE scan (guest) | **~29 ads / 8s** on fajita (Hue Lamp, Venus_*, sensors, …) |
| `com.android.btservices` | Apex has jars/JNI; stock image **strips app/** — restored via overlay (see below) |

### Guest bridge probe (repeatable)

```sh
# On phone (Waydroid session RUNNING, waydroid-bt-host active):
sudo $SBINDIR/waydroid-bt-inject-socket.sh
sudo $SBINDIR/waydroid-guest-bt-probe.sh
# LE scan from guest (8s):
sudo LE_SCAN_SECS=8 /usr/local/sbin/waydroid-guest-bt-probe.sh
# After session start, wait for LXC then inject:
sudo $SBINDIR/waydroid-bt-session-hook.sh
# Expect: PING_OK … ADAPTER_OK powered=true … LE_SCAN_OK ads=N … PROBE_OK
```

Install binaries from this repo on the phone after `cargo build --release -p waydroid-bt-host`:

```sh
# all of these are installed by scripts/install-host-system.sh into $SBINDIR / $LIBEXECDIR
sudo sh scripts/install-host-system.sh
```

### Restoring `Bluetooth.apk` (done on fajita)

Waydroid Lineage-20 intentionally removes the Bluetooth app from the apex
(`0001-hack-Remove-Bluetooth-app-from-apex.patch`). Restore with:

```sh
# APK + matching lib from a Lineage 20 (SDK 33) arm64 ROM apex
# (must match build family TQ3A / Android 13 — not Lineage 22 / A15)
sudo scripts/waydroid-restore-bluetooth-apk.sh \
  /path/to/Bluetooth.apk \
  /path/to/libbluetooth_jni.so
# then restart session (systemd-run --user recommended over bare SSH nohup)
waydroid session stop
sudo systemctl restart waydroid-container
# as Phosh user with WAYLAND_DISPLAY + DBUS:
systemd-run --user --unit=waydroid-session-manual \
  --setenv=XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR \
  --setenv=WAYLAND_DISPLAY=wayland-0 \
  --setenv=DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS \
  waydroid session start
```

**Verified on fajita:**

| Check | Result |
| --- | --- |
| Overlay paths | `overlay/system/apex/com.android.btservices/app/Bluetooth@TQ3A…/Bluetooth.apk` + matching `lib64/libbluetooth_jni.so` |
| `pm path com.android.bluetooth` | `package:/apex/com.android.btservices/app/Bluetooth@TQ3A.230901.001/Bluetooth.apk` |
| Package | `versionCode=33` `versionName=13` `sharedUser=android.uid.bluetooth` |
| Host bridge after restore | **PROBE_OK** (Ping + GetAdapterInfo) |
| `dumpsys bluetooth_manager` | **No** `Bluetooth Service not connected`; `AdapterProperties` present; process stable |

**Do not** install only as `/system/priv-app/Bluetooth` — PM then uses a codePath outside the apex and crashes with `UnsatisfiedLinkError: libbluetooth_jni.so not found`.

### Stabilize AdapterService bind (timerfd + BLE timeout)

After APK restore, Fluoride still hits two issues: (1) `timerfd_create(CLOCK_BOOTTIME_ALARM)` aborts without CAP_WAKE_ALARM; (2) default 4s BLE start timeout tears down the service when no HCI HAL exists.

```sh
# On the phone (root), from this repo:
sudo scripts/waydroid-bt-stabilize-adapter.sh
# restart Waydroid session, then:
sudo waydroid shell dumpsys bluetooth_manager
# expect: AdapterProperties, no "Bluetooth Service not connected"
```

What it does:

0. Refuses unless the image is Lineage 20 / Android 13 (SDK 33, build id `TQ3A*`), read from `system.img` via `debugfs` (`scripts/lib/lineage-guard.sh`; override `WAYDROID_BT_SKIP_VERSION_GUARD=1`). `waydroid-restore-bluetooth-apk.sh` has the same guard.
1. Patches overlay `libbluetooth_jni.so` with `waydroid-bt-jni-patch` (Rust, no python3; the `.py` is a desk fallback) — three AArch64 sites `mov w0,#9` → `#7` (BOOTTIME).
2. Seeds/appends `ro.bluetooth.ble_start_timeout_delay=86400000` on overlay `system/build.prop`.

**Hard next step for Android app BLE:** complete Alternative E so `bringUpBle` finishes (minimal HCI HAL **or** BlueZ-backed binder backend). Adapter may remain `BLE_TURNING_ON` until then; host BlueZ must stay sole radio owner.

## Day-2 — forwarders, field vs idle, desk check

After Soft HCI is working, install host→guest helpers and use short field windows:

```sh
# One-shot helpers (from repo checkout on phone)
sh scripts/install-waydroid-stack.sh
# optional live NFC packages (kernel may expose nfc0; userspace field is best-effort on OP6):
# sh scripts/install-waydroid-stack.sh --with-nfc-host-stack

phone-field-ready              # arm GPS+NFC units
phone-field-ready --with-logs  # + bt-log-session (drains battery)
# … car / sensor test …
phone-idle                     # stop bt-log-session; stop Waydroid session
```

| Topic | Where |
|-------|--------|
| GPS forward | [gps-forward.md](gps-forward.md) |
| NFC forward (not Soft NFC HAL; OP6 live NFC unproven) | [nfc-forward.md](nfc-forward.md) |
| Ready vs overnight drain | [phone-ready.md](phone-ready.md) |
| Log paths + desk pull | [field-logs.md](field-logs.md) |
| Soft HCI residuals | [soft-hci-residuals.md](soft-hci-residuals.md) |

### Charger cmdline / half-boot (OnePlus 6T)

Host `/proc/cmdline` often contains **both** `androidboot.mode=charger` (bootloader)
and `androidboot.mode=normal` (pmOS). Android init uses the first → Waydroid can
boot only the charger class (no zygote, session `RUNNING` + `IP UNKNOWN`).

```sh
waydroid-force-normal-boot install   # also done by install-waydroid-stack
waydroid-half-boot-fix             # soft then hard recovery; installs overlay if missing
```

### Charge / half-boot notes

- PC USB may not charge fajita even when SSH works over Wi‑Fi; prefer a wall brick for battery.
- Waydroid half-boot (`Session RUNNING`, `IP UNKNOWN`) skips GPS inject and NFC deliver until `sys.boot_completed=1`.
- GPS/NFC idle logs are **rate-limited**; full `bt-log-session` is the high-drain capture.

### Desk gate (laptop)

```sh
make check
# or: sh scripts/desk-check.sh
```

Runs forwarder selftests + `cargo test --workspace`.

```sh
# After a field session
sh scripts/pull-field-session.sh
# Offline summary of an existing tree:
sh scripts/pull-field-session.sh --local ./field-captures/pull-*/
```
