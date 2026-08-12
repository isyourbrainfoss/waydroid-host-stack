# Field stack changelog (recent)

- GPS: city-level GeoClue never injected when any last-known exists (including stale garage fix)
- `phone-field-ready` auto-runs half-boot recovery (opt out: `--no-fix-half-boot`)
- Docs: Soft HCI is the shipped field LE path; Strategy A (`IBluetooth`/`IBluetoothGatt` → BlueZ) is cleanup, not current stack
- **Charger boot fix (fajita):** `waydroid-force-normal-boot` overlay — host
  `androidboot.mode=charger` no longer leaves Waydroid without zygote
- Half-boot: session start is backgrounded (never `timeout`-killed); auto-installs force-normal-boot
- Soft HCI readiness: `phone-key-ready` (pure eval + live + `--selftest` / `--json` / `--require-guest`)
- Field evidence: golden fixture + live pull `session-20260807-214742` (path-up; no car)
- GPS inject after full boot confirmed with last-known
- Profiles: `phone-field-ready` calls `phone-key-ready` when installed; `--fix-half-boot`
- GPS: `seed` / `seed-from-host [--force|--force-coarse]`; save hygiene vs coarse GeoClue
- `pull-field-session`: REMOTE_HOME, skip-logcat default, Tesla timeline in SUMMARY
- `nfc-host-diag`: wiki-aware OP6 NFC diagnostic (libnfc-nci note; stock libnfc expected fail)
- `phone-battery-sample`: idle vs field_ready capacity samples
- `install-waydroid-stack` ships helpers including `phone-key-ready`
- Docs: `tesla-day-of.md`, NFC wiki notes in `nfc-forward.md`
