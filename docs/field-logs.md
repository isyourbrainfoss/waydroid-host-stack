# Field logs (BT / GPS / NFC)

## Profiles

```sh
phone-field-ready --with-logs   # start capture window
phone-idle                      # stop bt-log-session (+ Waydroid session)
```

## Where things live on the phone

| Stream | Path |
|--------|------|
| BT log session | `~/bt-log-sessions/session-YYYYMMDD-HHMMSS/` |
| GPS forward log | `$XDG_RUNTIME_DIR/waydroid-gps-forward/forward.log` |
| GPS last-known | `~/.local/state/waydroid-gps-forward/last-known.env` |
| NFC forward log | `$XDG_RUNTIME_DIR/waydroid-nfc-forward/forward.log` |
| NFC last-tag | `~/.local/state/waydroid-nfc-forward/last-tag.env` |
| Guest NFC delivery | `~/.local/share/waydroid/data/local/tmp/nfc-forward-last.txt` |
| Soft HCI host | `journalctl -u waydroid-bt-host` / session `waydroid-bt-host.follow.log` |

Typical user runtime: `/run/user/10000/…`. GPS/NFC skip lines are **rate-limited**.

## Pull to the desk

```sh
sh scripts/pull-field-session.sh           # latest BT session + GPS/NFC + Soft HCI journal
sh scripts/pull-field-session.sh --list
sh scripts/pull-field-session.sh session-20260804-200918
sh scripts/pull-field-session.sh --local ./path/to/capture
```

Creates `./field-captures/pull-*/` with:

- `bt-session/` — full BT log session
- `soft-hci/` — host journal + bridge tails when present
- `gps/` · `nfc/` — forward logs, last-known/last-tag, guest NFC file
- `SIZES.md` · `SUMMARY.md` — sizes + Tesla greps (`whitelist`, `BLEVehicleController`, …)

## Desk check

```sh
make check
# or just the host selftests + golden timeline:
sh tests/smoke-forwards.sh
sh tests/phone-key-golden-selftest.sh
```

## Golden Phone Key fixture

`tests/fixtures/phone-key-golden/` is a tiny offline capture tree that exercises
the compact Tesla timeline (`Did NOT find key` → whitelist → `unlocked`). Use it
to prove the pull/summary path without SSH to fajita.

## Tesla greps (manual)

```sh
rg -n 'whitelist|BLEVehicleController|b2d1|VCSEC|inject ok|deliver ok' \
  field-captures/pull-*/
```
