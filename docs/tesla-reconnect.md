# Tesla phone key: tolerant reconnect (car absent is normal)

FP5 bug B55 (17 Nov 2026). After the Tesla app's connect attempts failed while
the car was away (host scan "device not found", or a 25 s LE connect timeout),
nothing reconnected for hours, and resume didn't help either. Only a Waydroid
session restart did.

## Cause

* The Soft HCI HAL answered every failed host connect with an LE Connection
  Complete failure (0x3E) at once. A real controller never does that for an
  absent peer: an LE Create Connection stays pending until the peer shows up
  or the host stack cancels it. For a background (`autoConnect`, accept-list)
  connection that means "wait until the car is in range". The instant 0x3E
  made Android drop the background connection, so the app's own retry logic
  was cut off.
* One host attempt could take 12 s scan + 25 s connect = 37 s, longer than
  GD's 30 s direct-connect timeout. Android cancelled first, and the late
  result arrived for a connection the stack no longer had.
* A timed-out BlueZ `Connect()` stayed pending in the kernel, so the next
  attempt aborted right away (`le-connection-abort-by-local`).
* Host links opened by a guest socket that then went away were never dropped.

## Fix

Guest HAL (`guest/hal`):

* LE Create Connection keeps real-controller semantics. A failed host attempt
  is **not** reported: the connection stays pending, and the HAL retries the
  host link with backoff (2, 5, 10, 20, 30, 60 s, then every 90 s). It also
  retries at once after a resume from suspend. The stack ends it with
  LE Create Connection Cancel (Soft HCI answers 0x02, and any in-flight host
  attempt is aborted at once), or the car connects (0x00). Background connects
  rotate over the Filter Accept List. A direct connect falls back to 0x3E only
  if no cancel arrives within 60 s (safety net).
* Results are tied to an attempt generation, so a late host result for a
  cancelled attempt is dropped (and its host link closed).
* Only the first attempt pauses the guest scan.
* A persistent ping-only **keepalive** connection to the bridge for the whole
  HAL lifetime. It reattaches every 2 s after a bridge restart.

Host bridge (`host/`):

* `connect_le` uses one overall deadline (scan + connect ≤ guest timeout),
  an LE-only pre-connect scan, up to 3 rescans and retries after transient
  aborts, and cancels a timed-out BlueZ connect.
* Ping-only clients (`*-keepalive`) don't subscribe to events and don't count
  as active guests ("last guest gone" cleanup still stops discovery).
* LE links are owned by the IPC client that opened them, and are dropped when
  it disconnects without a Disconnect.
* `/run/waydroid-bt/bridge-status` (`keepalive=`, `ever=`, `changed=`) for
  the watchdog. It holds no addresses.

Safety net (`scripts/waydroid-bt-attach-watchdog.sh`, timer every 3 min plus
after resume):

* It restarts the `waydroid-session` user unit only if the keepalive has been
  gone for ≥ 60 s on two checks while the session has been active for ≥ 3 min.
  It acts at most once per 30 min and at most 6 times per boot, and logs one
  line. A missing car never triggers it.

## Tests

* `guest/hal/soft_hci_test.cpp`: an absent peer stays pending until cancel,
  then gets exactly one 0x02 and a late result is swallowed. Also covered:
  generations and reset, background accept-list snapshot, retry delays, a
  failed connect keeping the IPC usable, keepalive detach detection, and
  `shutdown_io` aborting an in-flight connect in about 100 ms.
* `cargo test`: retry budget, LE-only connect scan, request classification,
  link ownership, status file.
* `tests/attach-watchdog-selftest.sh`: the decision table plus an end-to-end
  run with a fake systemctl (strike → restart → rate-limited → quiet).
