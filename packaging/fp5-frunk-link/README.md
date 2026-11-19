# FP5 Frunk link fix (2026-11-19)

Staged bundle for BengalOS 0.26.1117.1 (Fairphone 5). **Not installed**; install needs Kristian's yes.

Problem (19 Nov, see FRUNK-QS-20261119.md): from boot the Frunk tile was greyed out ("Frunk (no car)")
because the car's LE link kept flapping: the kernel auto-connect came up and dropped within
milliseconds, before GATT resolved. The bridge only handed the link to the guest after a blocking
GATT wait, by which time it had dropped ("LE link lost: telling guest"). Presses on the greyed tile
were dropped without any log. Opening the Tesla app at ~10:50 happened to coincide with a link that held.

## What changes

| Part | Change |
|---|---|
| `waydroid-bt-host` (bridge) | Kernel auto-connect handed to the guest **immediately** (log: `LE device connected (kernel auto-connect): handing to guest now`); the auto-connect reference is held in the background until GATT resolves / drop / 10 s (`LE link hold: … outcome=resolved|dropped|timeout up_ms=…`). Every drop is logged with `up_ms`, `gatt_resolved`, `notify_streams`, `action`. An **early drop** (≤ `WHS_EARLY_DROP_MS`, default 1000 ms, or before GATT resolved within 10 s) on a link the guest is not using yet gets **one active reconnect** (`early drop: active reconnect ok, guest keeps its link`); otherwise the guest is told as before. SIGUSR1 = "kick": one active connect for every pending passive wait (`kick (SIGUSR1)…`, `kick: active connect ok/failed/timed out`). Writes `/run/waydroid-bt/features` (`kick-usr1 early-drop-reconnect pid=N`). Guest attach/retry and the session-restart drop-in are unchanged. |
| Frunk tile (phosh plugin) | Always tappable. Link down at press → label `Connecting…` (English, matches the existing labels), link up → `Frunk…`. Taps while a press runs are ignored and logged. Results: `Frunk command sent`, `Car not found (10 s)` (link was down), `Car not connected`, `Waydroid not running`, `Frunk busy`, `Could not send`. Each press/result is one `frunk-quick-setting:` line in the journal. |
| `tesla-frunk-root.sh` | Same safety checks (Waydroid RUNNING, live BlueZ VCSEC link, phone-key notification "Connected" + "Front Trunk") and the same send. If the link is down: kick the bridge (only if `features` names the running bridge PID; an old bridge would die on SIGUSR1) and wait up to 10 s for link + "Connected". `flock` against double sends. One line per press: `journalctl -t tesla-frunk` → `press result=sent|refused|busy|send-failed reason=… link_at_press=… kick=… waited_ms=…`. New exit 6 = busy. |
| `tesla-frunk.service` | `TimeoutStartSec=30` (was 20) to fit the 10 s wait. |

No addresses, VIN or names are logged anywhere.

## Install (on the phone, with Kristian's yes)

See `setup.sh` (pinned to a commit + sha256). It downloads, verifies, runs `run0 sh install.sh`
(password prompt), and does not restart anything unless `--restart-bridge` is given.

* backup + `rollback.sh`: `/var/lib/fp5-backup/20261119-frunk-link/`
* bridge active: after `run0 systemctl restart waydroid-bt-host` (→ Waydroid session restart via the
  60-session-restart drop-in) or reboot
* tile active: after reboot (phosh scans plugins at start; no `systemd-sysext refresh`)
* root script: immediately (daemon-reload done by install.sh)
* rollback: `run0 sh /var/lib/fp5-backup/20261119-frunk-link/rollback.sh [--restart-bridge]`

## Tests (box)

* `cargo test -p waydroid-bt-host --features waydroid-bt-host/vendored-dbus` (linkpolicy unit tests + existing)
* `sh packaging/tesla-frunk/sim/run-sim-tests.sh` (10 scenarios, all stubbed, never sends)
* `REF=<dir with 19 Nov binaries> sh packaging/fp5-frunk-link/test/run-install-test.sh` (fake-root install/rollback)

## Still open

The cause of the early drops (car side vs. phone controller vs. supervision timeout) needs a btmon/HCI
capture, which needs root on the phone (Kristian present).
