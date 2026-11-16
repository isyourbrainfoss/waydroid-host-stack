#!/bin/sh
# Selftest: waydroid-bt-stabilize-adapter.sh --build-prop-only keeps the overlay
# build.prop tied to the image's build.prop (re-seeds after an image change,
# moves it aside when the new image fails the version guard). Fakes debugfs.
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/overlay"
cat >"$T/bin/debugfs" <<'F'
#!/bin/sh
cat "$FAKE_PROP"
F
chmod +x "$T/bin/debugfs"
: >"$T/system.img"
mkprop() { # mkprop FILE BUILD_ID SDK
	{
		echo "ro.build.version.sdk=$3"
		echo "ro.build.id=$2"
		echo "ro.system.build.fingerprint=waydroid/lineage/$2:13/$2/1:user/release-keys"
		i=0
		while [ "$i" -lt 25 ]; do echo "ro.fake.prop$i=$2"; i=$((i + 1)); done
	} >"$1"
}
export PATH="$T/bin:$PATH" WHS_SELFTEST=1 WAYDROID_OVERLAY="$T/overlay" \
	WHS_STATE_DIR="$T/state" WAYDROID_SYSTEM_IMG="$T/system.img" FAKE_PROP="$T/prop"
S="$ROOT/scripts/waydroid-bt-stabilize-adapter.sh"
BP="$T/overlay/system/build.prop"
fail=0
ok() { echo "ok $*"; }
bad() { echo "FAIL $*"; fail=1; }
run() { sh "$S" "$@" 2>&1 || true; }

mkprop "$T/prop" TQ3A.230901.001 33
case "$(run --resync)" in *BUILD_PROP_NOT_MANAGED*) ok "resync leaves unmanaged hosts alone" ;; *) bad "resync seeded" ;; esac
[ ! -f "$BP" ] && ok "no copy created by resync" || bad "resync created copy"
case "$(run --build-prop-only)" in *BUILD_PROP_SEEDED*) ok seeded ;; *) bad seed ;; esac
grep -q '^ro.bluetooth.ble_start_timeout_delay=86400000' "$BP" && ok "timeout prop present" || bad "timeout prop"
case "$(run --build-prop-only)" in *BUILD_PROP_CURRENT*) ok "unchanged image keeps copy" ;; *) bad current ;; esac
case "$(run --check)" in *BUILD_PROP_CURRENT*) ok "check current" ;; *) bad "check current" ;; esac

# Waydroid OTA: same generation, new build.
mkprop "$T/prop" TQ3A.231005.001 33
if sh "$S" --check >/dev/null 2>&1; then bad "check should report stale"; else ok "check reports stale"; fi
case "$(run --resync)" in *BUILD_PROP_RESEEDED*) ok "re-seeded after image change" ;; *) bad reseed ;; esac
grep -q '^ro.fake.prop3=TQ3A.231005.001' "$BP" && ok "overlay has new image props" || bad "new props"
[ "$(grep -c '^ro.bluetooth.ble_start_timeout_delay=' "$BP")" = 1 ] && ok "timeout prop once" || bad "timeout prop count"

# Copy from an older script version (no stamp), same image: adopted, not re-seeded.
rm -f "$T/state/build-prop.src"
case "$(run --build-prop-only)" in *BUILD_PROP_ADOPTED*) ok "legacy copy adopted" ;; *) bad adopt ;; esac

# OTA to a generation the props are not for: copy moved aside.
mkprop "$T/prop" UQ1A.240105.002 34
case "$(run --resync)" in *BUILD_PROP_DISABLED*) ok "moved aside on unsupported image" ;; *) bad disable ;; esac
[ ! -f "$BP" ] && [ -f "$BP.whs-disabled" ] && ok "image build.prop applies" || bad "still overlaid"
mkprop "$T/prop" TQ3A.231105.001 33
case "$(run --resync)" in *BUILD_PROP_SEEDED*) ok "re-seeded when a supported image returns" ;; *) bad "reseed after disable" ;; esac

# Unreadable image: never touch the overlay.
mkprop "$T/prop" TQ3A.231005.001 33
run --build-prop-only >/dev/null
: >"$T/prop"
run --build-prop-only >/dev/null
[ -f "$BP" ] && ok "unreadable image leaves overlay" || bad "unreadable removed overlay"

[ "$fail" -eq 0 ] || { echo STABILIZE_SELFTEST_FAILED; exit 1; }
echo ALL_STABILIZE_SELFTESTS_OK
