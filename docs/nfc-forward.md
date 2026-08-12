# Host NFC → Waydroid forwarder (zero-touch)

Waydroid images on mainline phones typically ship `com.android.nfc` **without** a
bound NFC HAL (`dumpsys nfc` → service not found). Host Linux owns the PN553/NCI
controller (`/sys/class/nfc/nfc0`). This forwarder keeps **host as reader** and
delivers tag discoveries into the guest — GPS-forwarder style, not a Soft NFC HAL.

## Zero-touch install

```sh
sh scripts/install-waydroid-nfc-forward.sh
# Optional live field readers (Alpine/pmOS):
sh scripts/install-waydroid-nfc-forward.sh --with-host-stack
# or later:
waydroid-nfc-forward install-host-stack   # apk add neard libnfc-tools
```

| Piece | Role |
|-------|------|
| `~/.local/bin/waydroid-nfc-forward` | Daemon + deliver logic |
| `~/.config/systemd/user/waydroid-nfc-forward.service` | Survives logout; login-enabled |
| `~/.config/autostart/waydroid-nfc-forward.desktop` | Arms at Phosh login |
| `~/.local/bin/waydroid-nfc-session-hook` | Called from Waydroid UI start |

No toggle needed for normal use. The loop always runs; **deliver only when**
`sys.boot_completed=1`.

## Commands

```sh
waydroid-nfc-forward status
waydroid-nfc-forward enable
waydroid-nfc-forward disable
waydroid-nfc-forward once
waydroid-nfc-forward push uri 'https://example.com/tag'   # fixture through shipped path
waydroid-nfc-forward push text 'hello from host'
waydroid-nfc-forward selftest
```

## Host sources (priority)

1. **Push / fixture** — `push` CLI or `~/.local/state/waydroid-nfc-forward/fixture.tag`
2. **neard** (D-Bus) — install `neard` on pmOS when you want live polling
3. **libnfc-tools** (`nfc-list`) — optional
4. **Last tag** — `~/.local/state/waydroid-nfc-forward/last-tag.env`

On fajita, kernel `nxp-nci_i2c` / `nfc0` is present; userspace may need
`apk add neard` or `libnfc-tools` for live field reads (`install-host-stack`).
`NFC_FWD_HOST_STACK=auto|neard|libnfc|none` selects readers; idle logs are rate-limited.

## Guest delivery

Because the Android NFC service is usually **not bound** (no NCI HAL):

1. Writes `/data/local/tmp/nfc-forward-last.txt` (uid/type/payload/source)
2. Broadcasts `com.waydroid.nfc.FORWARD` with string extras
3. For URI tags, tries `VIEW` and `NDEF_DISCOVERED` (succeeds if an app resolves)

Guest inject uses a **guest-side script** (same lesson as GPS: do not pass raw
`--flags` through `waydroid shell`).

## Limits

- Not a Soft NFC HAL / dual-master NCI stack; host owns the radio.
- Not HCE, SE, payments, or car-key NFC roles.
- Live tag polling needs neard or libnfc-tools; without them use `push` / fixture.
- Many apps only listen via the system NFC service; broadcast + file still provide
  a usable discovery path and verification surface.

## Related

- GPS: `docs/gps-forward.md`
- Soft HCI Bluetooth (Phone Key): Soft HCI path in this repo

## OP6 / fajita hardware note (pmOS wiki + field)

[postmarketOS wiki (OP6)](https://wiki.postmarketos.org/wiki/OnePlus_6_(oneplus-enchilada)) states:

- Kernel/DT NFC can work after enabling the NFC I2C node (see community `NFC.patch`:
  `status = "okay"` + GPIO pin states for VEN/INT).
- Userspace is incomplete: Alpine **`libnfc` is the USB PN53x stack** — it will report
  **“No NFC device”** on kernel NCI. The wiki points at **NXP libnfc-nci**, which is
  not an Alpine package.
- TrustZone/QSEE is separate (HCE/secure NFC); not required for passive tag read.

On fajita we observe: `nxp_nci_i2c` + `nfc0` + neard **Powered/Polling**, but **no
`org.neard.Tag`** with a ski card under the phone. So RF discovery is still not
working end-to-end despite the driver node.

```sh
nfc-host-diag --poll-seconds 12   # wiki-aware host dump
```

Prefer `push` / fixture for guest delivery tests until Tag objects appear. Soft NFC HAL out of scope.
