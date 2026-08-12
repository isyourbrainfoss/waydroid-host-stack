# Tesla day-of checklist (fajita)

One page for a short Phone Key / field BT window. Full detail: [phone-ready.md](phone-ready.md).

## Before you leave the desk

1. Charge on a **wall brick** if PC USB does not charge.
2. Desk gate (optional): `make check`
3. Phone on Wi‑Fi; Soft HCI host up (`waydroid-bt-host` active).

## At the car (short window)

```sh
# First time / after reimage:
#   waydroid-force-normal-boot install   # fajita charger-cmdline fix
phone-key-ready                               # host Soft HCI must be READY
phone-field-ready --with-logs --fix-half-boot
phone-key-ready --require-guest               # full boot + guest BT bound
# Use Tesla Phone Key as usual (key card enroll if needed)
```

When finished:

```sh
phone-idle
```

## After / on the laptop

```sh
sh scripts/pull-field-session.sh              # latest BT session + GPS/NFC + Soft HCI
# sh scripts/pull-field-session.sh --full-logcat   # huge logs
rg -n 'whitelist|BLEVehicleController|unlocked' field-captures/pull-*/

# Desk proof without the phone (golden timeline fixture):
sh scripts/pull-field-session.sh --local tests/fixtures/phone-key-golden
```

## Do not

- Leave `bt-log-session` + full Waydroid armed overnight.
- Expect OP6 **live NFC** (ski card) without verifying neard sees a Tag — hardware may expose `nfc0` without usable reads.

## Install once

```sh
sh scripts/install-waydroid-stack.sh
```
