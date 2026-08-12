# Manifest / version pinning

Pin the Waydroid image generation you build against before landing binary
guest backends:

| Item | Pin |
|------|-----|
| Waydroid tools | _TBD_ |
| Android / Lineage branch | _TBD_ (e.g. lineage-20) |
| Arch | arm64 (phones), optionally x86_64 for desktop bring-up |
| Vendor tree commit | _TBD_ |

Record the commit that still contains (or reverts) the Bluetooth APEX removal
hack so rebuilds stay reproducible.
