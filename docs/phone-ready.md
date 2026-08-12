# Phone ready / idle drain checklist (fajita)

Use **profile scripts** for a short field window, then idle again. Do not leave
`bt-log-session` + full Waydroid armed overnight.

## Commands

```sh
phone-key-ready                # Soft HCI + BlueZ (+ optional --require-guest)
phone-field-ready              # arm GPS + NFC (idempotent; health + phone-key-ready)
phone-field-ready --with-logs  # also start bt-log-session (near the car)
phone-field-ready                  # also auto-recovers half-boot (charger overlay)
phone-field-ready --no-fix-half-boot  # detect only, do not restart
phone-idle                     # stop bt-log-session; stop Waydroid session
phone-idle --keep-waydroid     # only stop field logs
waydroid-force-normal-boot install  # once on fajita (charger cmdline → full boot)
waydroid-half-boot-fix       # soft then hard recovery (no hang on getprop)
waydroid-gps-forward seed-from-host   # lock good GeoClue into last-known
```

Dry-run (no side effects): add `--dry-run` where supported. Pure desk tests:
`phone-key-ready --selftest`, `waydroid-half-boot-fix --selftest`.

**Day-of Tesla:** [tesla-day-of.md](tesla-day-of.md).

## Ready for Phone Key (short window)

1. Charge to a solid % (**wall brick** if PC USB does not charge).
2. `phone-key-ready` → must print `READY` / `PHONE_KEY_READY_OK` (host Soft HCI path).
3. `phone-field-ready --with-logs` when walking to the car.
4. Full Waydroid boot: Session RUNNING, real IP (not UNKNOWN), `sys.boot_completed=1`
   (`waydroid-half-boot-fix` or `phone-field-ready --fix-half-boot`).
5. Optional gate before unlock: `phone-key-ready --require-guest` (full boot + guest BT).
6. After the test: **`phone-idle`**, then `pull-field-session` on the desk.

Manual checks if needed:

```sh
phone-key-ready --require-guest
waydroid-bt-host status 2>/dev/null || systemctl status waydroid-bt-host --no-pager | head
bluetoothctl show | head -5
waydroid status
waydroid-gps-forward status
waydroid-nfc-forward status
```

## Idle / overnight

| Leave ON | Stop |
|----------|------|
| Host BlueZ if you need host BT | `bt-log-session` / field logcat |
| GPS/NFC user units (cheap skips) | Waydroid session overnight |
| Wall charger | “Ready” posture all night |

## Install

```sh
sh scripts/install-waydroid-stack.sh
# or individually:
sh scripts/install-waydroid-gps-forward.sh
sh scripts/install-waydroid-nfc-forward.sh
sh scripts/install-bt-log-session.sh
```

## NFC note (OP6 / fajita)

Kernel may expose `nfc0` (NXP PN553). **Live tag reading is unproven** on mainline
pmOS; the NFC forwarder is still useful via `push`/fixture/last-tag. Do not plan
field work on OP6 NFC until you confirm a tag with neard.

## Related

- [gps-forward.md](gps-forward.md) · [nfc-forward.md](nfc-forward.md) · [field-logs.md](field-logs.md)
- [pmOS-setup.md](pmOS-setup.md) (day-2 section) · [soft-hci-residuals.md](soft-hci-residuals.md)
