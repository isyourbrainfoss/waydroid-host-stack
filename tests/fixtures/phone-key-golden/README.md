# Golden Phone Key fixture

Offline capture tree for desk proof of the field evidence loop:

1. `pull-field-session.sh --local` over this directory
2. `SUMMARY.md` must include the compact **Tesla Phone Key timeline**
3. Hits: `Did NOT find key` → `Found […] in whitelist` → `unlocked`

Synthetic lines mirror the successful fajita session pattern
(`session-20260804-200918`) without shipping multi‑MB logcat.

```sh
sh scripts/pull-field-session.sh --local tests/fixtures/phone-key-golden
rg -n 'whitelist|unlocked' tests/fixtures/phone-key-golden/SUMMARY.md
```
