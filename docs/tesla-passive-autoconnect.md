# Tesla phone key: passive background connect (BlueZ auto-connect)

FP5 follow-up to [tesla-reconnect.md](tesla-reconnect.md) (B55), 17 Nov 2026.

## Problem

With B55 the guest HAL keeps the Tesla app's background connect
(`autoConnect`, Filter Accept List, policy 0x01) pending, but it polls: every
retry is a 12 s *active* BlueZ scan plus Connect, backing off to every 90 s.
Walking up to the car can therefore take up to ~100 s before the phone key
connects, and the active scans cost power for as long as the car is away.
A real (Android) controller instead keeps a low-duty *passive* scan with the
accept list running and connects the moment the car advertises.

## Change

* Guest HAL: for a background connect, the first host attempt stays the
  quick active one (car right there). After that the HAL sends
  `ConnectLe { wait_passive: true, timeout_ms: 600000 }` (60 s per peer when
  the accept list holds several, round-robin). The connection stays pending
  for the stack exactly as before; when the wait ends without a link the HAL
  re-arms at once. Direct connects (policy 0x00) are unchanged.
* Host bridge: `wait_passive` puts the peer on the kernel LE auto-connect
  list (mgmt Add Device, action 0x02) and waits, without any active scan, for
  BlueZ to report the device connected (D-Bus signals; a 30 s property
  re-check as safety net). It then removes the entry again and answers like a
  normal ConnectLe; the HAL continues with GATT discovery as usual. On
  timeout it answers `ERROR_CODE_TIMEOUT`.
* Cancel: the HAL's LE Create Connection Cancel still shuts the request
  socket down. The bridge now watches the socket while a passive wait runs:
  EOF drops the wait and disarms the kernel entry at once. A waiting client
  gets no event fan-out (its event sink is registered only after the wait).
* Fallback: if the bridge cannot use mgmt (no `AF_BLUETOOTH` /
  `CAP_NET_ADMIN`), it answers `ERROR_CODE_UNSUPPORTED` and the HAL goes back
  to the B55 active retries for 30 min before trying passive again.
* Unit: `RestrictAddressFamilies=AF_UNIX AF_BLUETOOTH` (repo unit; drop-in
  `packaging/systemd/waydroid-bt-host.service.d/70-passive-autoconnect.conf`
  for installed units).
* BlueZ timing (`packaging/bluetooth/main.conf.passive-autoconnect`):
  `[LE] ScanIntervalAutoConnect=0x0800`, `ScanWindowAutoConnect=0x0030`
  (30 ms every 1.28 s, as AOSP's background connect). bluetoothd loads it when
  it sets up the adapter, i.e. at the next boot. Until then the kernel default
  (30 ms every 60 ms) applies while a passive wait is armed.

Kept from B55: pending semantics, generations, the HAL keepalive, the attach
watchdog and the bridge-restart session restart.

## Not in scope

* Wake from suspend (no wake flag, BT UART wakeup stays disabled). While the
  phone is in s2idle nothing scans; the kernel resumes the passive scan by
  itself after resume.
* Mirroring the Android phone-key notification to the host.

## Power

While a background connect is pending and the phone is awake: controller
passive scan at ~2.3 % duty with accept-list filtering in the controller, no
host CPU work until the car connects, versus B55's 12 s active scan every
90 s (~12 % active duty plus host wake-ups for every advertisement).

## Tests

* `guest/hal/soft_hci_test.cpp`: passive policy (first attempt active,
  direct connects never passive, unsupported fallback, wait lengths, re-arm
  backoff), `wait_passive` + address type on the wire, TIMEOUT/UNSUPPORTED
  error codes with the socket kept usable, `shutdown_io` aborting a passive
  wait in ~100 ms.
* `cargo test`: mgmt packet layout, little-endian address parsing, reply
  matching, address-type mapping, passive request detection, wait default
  and cap.
