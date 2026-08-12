# Soft HCI readiness + field evidence loop

Goal slice: keep the **Phone Key class** Soft HCI path operable day-to-day and
prove the evidence loop on the desk without needing the car every change.

**Shipped vs cleanup:** Soft HCI is the **current field LE path** (host BlueZ +
guest Soft HCI HAL). Strategy A (`IBluetooth` / `IBluetoothGatt` → same BlueZ
IPC) is the cleanup north star, **not** the stack you run on fajita today.

## Readiness probe

```sh
phone-key-ready                 # host Soft HCI bin + unit + sock + BlueZ
phone-key-ready --require-guest # also full Waydroid + guest BT bound
phone-key-ready --selftest      # pure classification (no hardware)
phone-key-ready --json          # machine-readable summary
```

Fail-closed on missing host binary, inactive unit, missing `host.sock`, or
BlueZ powered-off. Guest checks are opt-in via `--require-guest`.

## Half-boot recovery

```sh
waydroid-force-normal-boot install   # once: fix charger cmdline (fajita)
waydroid-half-boot-fix --check-only
waydroid-half-boot-fix           # soft session restart, then hard container bounce
```

- **Charger-mode trap (fajita):** host kernel cmdline includes `androidboot.mode=charger`
  (bootloader) **and** `androidboot.mode=normal` (pmOS). Android takes the first →
  guest stays in charger class (no zygote, `IP UNKNOWN`).  
  Fix: `waydroid-force-normal-boot install` writes an overlay init.rc that on
  `charger` also `class_start main` / triggers normal boot.  
  `install-waydroid-stack` and `waydroid-half-boot-fix` install this automatically.
- `getprop` / `waydroid status` are hard-capped with `timeout` (no wedge).
- Soft path: background `session start` (**never** `timeout`-wrapped — that kills the session) + coldboot poke.
- Hard path: container stop → `systemctl start waydroid-container` → session start.
- Same classification as `phone-key-ready` (`full` / `half` / `stopped`).

## Field evidence loop

1. On phone: `phone-field-ready --with-logs` (± `--fix-half-boot`).
2. Exercise Phone Key / BLE apps.
3. `phone-idle`.
4. On desk: `pull-field-session` → `SUMMARY.md` Tesla timeline.

Offline desk proof (no SSH):

```sh
sh tests/phone-key-golden-selftest.sh
# or:
sh scripts/pull-field-session.sh --local tests/fixtures/phone-key-golden
```

Golden fixture mirrors the successful whitelist → unlock pattern from
`session-20260804-200918` without shipping multi-MB logcat.

## Related

- [phone-ready.md](phone-ready.md) · [tesla-day-of.md](tesla-day-of.md)
- [field-logs.md](field-logs.md) · [soft-hci-residuals.md](soft-hci-residuals.md)
