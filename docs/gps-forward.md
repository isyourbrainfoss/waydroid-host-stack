# Host GPS → Waydroid forwarder (zero-touch)

Waydroid images do not expose host GNSS. This forwarder reads host location
(GeoClue2 / ModemManager) and injects into Android **test location providers**,
with **last-known** fallback when the phone is indoors / garage.

## Zero-touch install

```sh
# From repo checkout on the phone (or scp scripts then):
sh scripts/install-waydroid-gps-forward.sh
```

That installs:

| Piece | Role |
|-------|------|
| `~/.local/bin/waydroid-gps-forward` | Daemon + inject logic |
| `~/.config/systemd/user/waydroid-gps-forward.service` | Survives logout; enabled for login |
| `~/.config/autostart/waydroid-gps-forward.desktop` | Arms at Phosh login |
| `~/.local/bin/waydroid-gps-session-hook` | Called from Waydroid UI start |

You should **not** need to toggle GPS for normal Waydroid use. The loop always
runs; inject only happens when `sys.boot_completed=1`.

## Commands

```sh
waydroid-gps-forward status
waydroid-gps-forward enable   # install unit + start (default path)
waydroid-gps-forward disable
waydroid-gps-forward once     # single cycle
waydroid-gps-forward selftest # pure logic tests (no guest required)
```

## Behaviour

| Source | When |
|--------|------|
| **GeoClue2** | Preferred — same stack as Phosh Maps |
| **ModemManager** | Fallback |
| **Last known good** | Garage / no live fix; file: `~/.local/state/waydroid-gps-forward/last-known.env` |

- Soft provider setup (no thrashing remove/add every cycle).
- Hard recreate only every 3rd failed streak (3, 6, 9…) after soft retries.
- Host last-known is updated even when the guest is down.
- Inject is gated on `sys.boot_completed=1` (half-boot / `IP UNKNOWN` → skip inject, keep last-known).
- Coarse live GeoClue (worse than `GPS_FWD_MAX_LIVE_ACC`, default 500 m) prefers a better last-known when available — **including stale last-known**. City-level Wi‑Fi (~25 km) is never injected as “current” if a garage last-known exists.
- Last-known **file** is not overwritten by a coarser live fix (`should_update_last_known` on save).
- Idle skip / identical inject lines are rate-limited (`GPS_FWD_LOG_IDLE_S`, default 60 s).
- Guest inject is written via a temp script under the Waydroid data dir — **not**
  `waydroid shell sh -c '… --location …'`, because the host `waydroid` CLI
  parses flags itself and rejects `--location` / `-c` unless separated carefully.

## Garage

If Maps on pmOS still shows a position, that is forwarded. If GeoClue has
nothing, last-known is injected so Android does not see an empty location.

## Limits

- Still a **test-provider** path (mock flag), not a Soft GNSS HAL.
- Requires full Android boot for inject success.
- Does not fix microG Play fused-location / Integrity.

## Longer-term direction

Stable Soft HCI BT (done for Phone Key) + this GPS forwarder + NFC forwarder
(`docs/nfc-forward.md`) for a full Linux-phone Android stack path.
