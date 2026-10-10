#!/bin/sh
# Forward host (postmarketOS / Linux) location into Waydroid via Android test providers.
#
# Host sources (in order):
#   1) GeoClue2 (same stack Phosh Maps uses)
#   2) ModemManager GPS when available
#   3) Last known good fix (persisted under XDG_STATE_HOME)
#
# Auto-arm: install the user unit (install-waydroid-gps-forward.sh) or call
# `waydroid-gps-forward enable`. The loop runs always; inject only when the
# guest is fully booted. No desktop toggle required for normal use.
#
# Usage:
#   waydroid-gps-forward start|stop|status|toggle|once|enable|disable|selftest
#   waydroid-gps-forward seed [lat lon acc]   # force good last-known (default SEED_*)
#   waydroid-gps-forward seed-from-host       # save current host fix if good enough
#
# Env:
#   GPS_FWD_INTERVAL   seconds between cycles (default 3)
#   GPS_FWD_MAX_AGE    max age of last-known before STALE (default 86400)
#   GPS_FWD_MIN_ACC    floor accuracy metres (default 8)
#   GPS_FWD_STALE_ACC  accuracy for aged last-known (default 80)
#   GPS_FWD_MAX_LIVE_ACC  if live fix is worse than this (m) and any valid
#                         last-known exists (even stale), prefer last-known
#                         so city-level GeoClue is never the guest inject (default 500)
#   GPS_FWD_LOG_IDLE_S rate-limit idle skip logs (default 60)
#   GPS_FWD_SEED_LAT/LON/ACC  bootstrap / seed CLI defaults (override for your area)
set -eu

INTERVAL="${GPS_FWD_INTERVAL:-3}"
MAX_AGE="${GPS_FWD_MAX_AGE:-86400}"
MIN_ACC="${GPS_FWD_MIN_ACC:-8}"
STALE_ACC="${GPS_FWD_STALE_ACC:-80}"
MAX_LIVE_ACC="${GPS_FWD_MAX_LIVE_ACC:-500}"
LOG_IDLE_S="${GPS_FWD_LOG_IDLE_S:-60}"
SEED_LAT="${GPS_FWD_SEED_LAT:-59.91}"
SEED_LON="${GPS_FWD_SEED_LON:-10.75}"
SEED_ACC="${GPS_FWD_SEED_ACC:-50}"

STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/waydroid-gps-forward"
RUNTIME="${XDG_RUNTIME_DIR:-/tmp}/waydroid-gps-forward"
PIDFILE="$RUNTIME/loop.pid"
LOGFILE="$RUNTIME/forward.log"
LASTFILE="$STATE_ROOT/last-known.env"
FAILFILE="$RUNTIME/inject-fail-streak"
INJECT_HASH="$RUNTIME/last-inject.hash"
GDATA="${HOME}/.local/share/waydroid/data/local/tmp"
UNIT_NAME="waydroid-gps-forward.service"

mkdir -p "$STATE_ROOT" "$RUNTIME"

notify() {
  title="$1"
  body="$2"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -a "Waydroid GPS" -i find-location "$title" "$body" 2>/dev/null || true
  fi
  logger -t waydroid-gps-forward "$title: $body" 2>/dev/null || true
}

log() {
  echo "$(date -Is 2>/dev/null || date) $*" >>"$LOGFILE" 2>/dev/null || true
}

# Rate-limited log (key + min seconds). Avoids flooding when Waydroid is down.
log_rate() {
  key="$1"
  min_s="$2"
  shift 2
  stamp="$RUNTIME/lograte.$key"
  now=$(date +%s)
  prev=$(cat "$stamp" 2>/dev/null || echo 0)
  case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
  if [ $((now - prev)) -ge "$min_s" ]; then
    echo "$now" >"$stamp" 2>/dev/null || true
    log "$@"
  fi
}

ws() {
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo -n waydroid shell "$@"
  else
    waydroid shell "$@"
  fi
}

# Soft shell: never trip set -e for the caller.
ws_soft() {
  ws "$@" 2>/dev/null || true
}

waydroid_session_running() {
  st=$(waydroid status 2>/dev/null | sed -n 's/^Session:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
  case "$st" in
    RUNNING*) return 0 ;;
    *) return 1 ;;
  esac
}

# Full guest Android boot (not just LXC half-up).
guest_boot_ready() {
  waydroid_session_running || return 1
  boot=$(ws_soft getprop sys.boot_completed | tr -d '\r\n' | head -1)
  [ "$boot" = "1" ]
}

is_running() {
  if systemctl --user is-active "$UNIT_NAME" >/dev/null 2>&1; then
    return 0
  fi
  [ -f "$PIDFILE" ] || return 1
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

# --- last-known (pure enough for selftest) ----------------------------------

seed_last_known_if_missing() {
  if [ -f "$LASTFILE" ]; then
    return 0
  fi
  cat >"$LASTFILE" <<EOF
LAT=$SEED_LAT
LON=$SEED_LON
ACC=$SEED_ACC
ALT=
SPEED=
BEARING=
SOURCE=seed
TS=$(date +%s)
EOF
  log "seeded last-known from defaults LAT=$SEED_LAT LON=$SEED_LON"
}

load_last_known() {
  seed_last_known_if_missing
  # shellcheck source=/dev/null
  . "$LASTFILE"
  LAST_LAT="${LAT:-}"
  LAST_LON="${LON:-}"
  LAST_ACC="${ACC:-$STALE_ACC}"
  LAST_ALT="${ALT:-}"
  LAST_SPEED="${SPEED:-}"
  LAST_BEARING="${BEARING:-}"
  LAST_SOURCE="${SOURCE:-unknown}"
  LAST_TS="${TS:-0}"
}

save_last_known() {
  lat="$1"
  lon="$2"
  acc="$3"
  alt="${4:-}"
  speed="${5:-}"
  bearing="${6:-}"
  source="${7:-host}"
  now=$(date +%s)
  cat >"$LASTFILE.tmp" <<EOF
LAT=$lat
LON=$lon
ACC=$acc
ALT=$alt
SPEED=$speed
BEARING=$bearing
SOURCE=$source
TS=$now
EOF
  mv -f "$LASTFILE.tmp" "$LASTFILE"
}

# Pure: should a new live fix replace persisted last-known?
# Usage: should_update_last_known new_acc old_acc old_ts now max_age max_live_acc
# Exit 0 = yes, update; 1 = keep old (new is coarser / not worth it).
# - Empty/invalid old → update
# - Stale old → update only if new_acc <= max_live_acc (do not reseal with city-level junk)
# - Fresh old → update only if new is not meaningfully worse (≤1.2× and ≤+10m)
should_update_last_known() {
  new_acc="$1"
  old_acc="$2"
  old_ts="$3"
  now="$4"
  max_age="$5"
  max_live="$6"
  case "$new_acc" in ''|*[!0-9.]* ) return 1 ;; esac
  case "$old_acc" in ''|*[!0-9.]* ) return 0 ;; esac
  case "$old_ts" in ''|*[!0-9]* ) return 0 ;; esac
  age=$((now - old_ts))
  if [ "$age" -gt "$max_age" ]; then
    awk -v n="$new_acc" -v m="$max_live" 'BEGIN { exit !((n + 0) <= (m + 0)) }'
    return $?
  fi
  awk -v n="$new_acc" -v o="$old_acc" 'BEGIN {
    n = n + 0; o = o + 0
    if (n <= o) exit 0
    if (n <= o * 1.2 && n <= o + 10) exit 0
    exit 1
  }'
}

valid_coords() {
  # Use private names — never clobber caller lat/lon (shell vars are global).
  _vc_lat="$1"
  _vc_lon="$2"
  case "$_vc_lat" in
    ''|*[!0-9.+-]*) return 1 ;;
  esac
  case "$_vc_lon" in
    ''|*[!0-9.+-]*) return 1 ;;
  esac
  awk -v la="$_vc_lat" -v lo="$_vc_lon" 'BEGIN {
    if (la < -90 || la > 90 || lo < -180 || lo > 180) exit 1
    if (la == 0 && lo == 0) exit 1
    exit 0
  }'
}

clamp_acc() {
  awk -v a="${1:-50}" -v m="$MIN_ACC" 'BEGIN {
    if (a+0 < m) a=m
    if (a+0 > 2000) a=2000
    printf "%.1f", a+0
  }'
}

# Pure: pick fix fields from a pipe line or fall back to last-known args.
# Usage: pick_fix line last_lat last_lon last_acc last_ts now max_age stale_acc min_acc [max_live_acc]
# Prints: LIVE|…  OR  LAST|…
# If live accuracy is worse than max_live_acc (default 500) and last-known is
# valid and better, prefer last-known — including stale last-known. City-level
# GeoClue (~25 km) must not become the guest inject when a garage fix exists.
pick_fix_from_line() {
  line="$1"
  last_lat="$2"
  last_lon="$3"
  last_acc="$4"
  last_ts="$5"
  now="$6"
  max_age="$7"
  stale_acc="$8"
  min_acc="$9"
  max_live_acc="${10:-500}"

  live_ok=0
  lat=""; lon=""; acc=""; alt=""; speed=""; bearing=""; source=""
  if [ -n "$line" ]; then
    # Parse with cut — avoid `set -- $line` which can leave outer $@ in some shells
    # when called from selftest under certain IFS/state.
    lat=$(printf '%s' "$line" | cut -d'|' -f1)
    lon=$(printf '%s' "$line" | cut -d'|' -f2)
    acc=$(printf '%s' "$line" | cut -d'|' -f3)
    alt=$(printf '%s' "$line" | cut -d'|' -f4)
    speed=$(printf '%s' "$line" | cut -d'|' -f5)
    bearing=$(printf '%s' "$line" | cut -d'|' -f6)
    source=$(printf '%s' "$line" | cut -d'|' -f7)
    [ -n "$acc" ] || acc=50
    [ -n "$source" ] || source=host
    case "$alt" in -|"") alt= ;; esac
    case "$speed" in -|"") speed= ;; esac
    case "$bearing" in -|"") bearing= ;; esac
    if valid_coords "$lat" "$lon"; then
      # Keep raw accuracy for coarse/live decision; clamp only for LIVE output.
      live_raw_acc=$acc
      acc=$(awk -v a="$acc" -v m="$min_acc" 'BEGIN{ if (a+0 < m) a=m; if (a+0 > 2000) a=2000; printf "%.1f", a+0 }')
      live_ok=1
    fi
  fi

  last_ok=0
  last_out_acc=""
  last_src=""
  if valid_coords "$last_lat" "$last_lon"; then
    last_ok=1
    age=$((now - last_ts))
    if [ "$age" -gt "$max_age" ]; then
      last_out_acc=$stale_acc
      last_src="last-known-stale"
    else
      last_out_acc=$(awk -v a="$last_acc" -v s="$stale_acc" 'BEGIN{
        a=a+0; if (a < 20) a=20; if (a < s/2) a=a*1.5; if (a > s) a=s; printf "%.1f", a
      }')
      last_src="last-known"
    fi
  fi

  if [ "$live_ok" = "1" ]; then
    prefer_last=0
    if [ "$last_ok" = "1" ]; then
      # Compare raw live accuracy (e.g. GeoClue 25000m) to threshold, not clamped 2000.
      # Stale last-known still wins over city-level live (honest garage vs Wi‑Fi city).
      prefer_last=$(awk -v la="${live_raw_acc:-$acc}" -v ml="$max_live_acc" -v lk="$last_out_acc" 'BEGIN{
        if ((la+0) > (ml+0) && (lk+0) > 0 && (lk+0) < (la+0)) print 1; else print 0
      }')
    fi
    if [ "$prefer_last" = "1" ]; then
      echo "LAST|$last_lat|$last_lon|$last_out_acc||||$last_src"
      return 0
    fi
    echo "LIVE|$lat|$lon|$acc|$alt|$speed|$bearing|$source"
    return 0
  fi

  if [ "$last_ok" = "1" ]; then
    echo "LAST|$last_lat|$last_lon|$last_out_acc||||$last_src"
    return 0
  fi
  return 1
}

# --- host location sources --------------------------------------------------

# Root path (preferred): waydroid-geoclue-fix.service mirrors GeoClue into
# this file and waydroid-gps-inject.service injects it (no sudo, no python3).
ROOT_FIX="${WAYDROID_GPS_FIX:-/run/waydroid-host-stack/gps-fix}"

root_inject_active() {
  systemctl is-active --quiet waydroid-gps-inject.service 2>/dev/null
}

read_geoclue() {
  if [ -s "$ROOT_FIX" ]; then
    IFS='|' read -r _lat _lon _acc _alt _spd _hdg _ts _desc <"$ROOT_FIX" || true
    _now=$(date +%s)
    if [ -n "${_lat:-}" ] && [ -n "${_lon:-}" ] && [ $((_now - ${_ts:-0})) -le 120 ]; then
      echo "${_lat}|${_lon}|${_acc:-50}|${_alt:-}|${_spd:-}|${_hdg:-}|geoclue"
      return 0
    fi
  fi
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - <<'PY' 2>/dev/null || true
import sys
try:
    import dbus
except ImportError:
    sys.exit(0)
import time

try:
    bus = dbus.SystemBus()
    manager = bus.get_object("org.freedesktop.GeoClue2", "/org/freedesktop/GeoClue2/Manager")
    mi = dbus.Interface(manager, "org.freedesktop.GeoClue2.Manager")
    path = mi.GetClient()
    client = bus.get_object("org.freedesktop.GeoClue2", path)
    props = dbus.Interface(client, "org.freedesktop.DBus.Properties")
    iface = "org.freedesktop.GeoClue2.Client"
    props.Set(iface, "DesktopId", "waydroid-gps-forward")
    props.Set(iface, "RequestedAccuracyLevel", dbus.UInt32(8))
    props.Set(iface, "DistanceThreshold", dbus.UInt32(0))
    props.Set(iface, "TimeThreshold", dbus.UInt32(0))
    dbus.Interface(client, iface).Start()
    loc_path = "/"
    for _ in range(8):
        loc_path = str(props.Get(iface, "Location"))
        if loc_path and loc_path != "/":
            break
        time.sleep(0.4)
    if not loc_path or loc_path == "/":
        sys.exit(0)
    lo = bus.get_object("org.freedesktop.GeoClue2", loc_path)
    lp = dbus.Interface(lo, "org.freedesktop.DBus.Properties")
    li = "org.freedesktop.GeoClue2.Location"

    def g(name, default=""):
        try:
            v = lp.Get(li, name)
            if isinstance(v, dbus.Struct):
                return str(int(v[0]))
            return str(v)
        except Exception:
            return default

    def clean_num(s, allow_neg=False):
        if s is None or s == "":
            return ""
        try:
            v = float(s)
        except Exception:
            return ""
        if abs(v) > 1e100:
            return ""
        if not allow_neg and v < 0:
            return ""
        return f"{v:.8f}".rstrip("0").rstrip(".")

    lat = clean_num(g("Latitude"), allow_neg=True)
    lon = clean_num(g("Longitude"), allow_neg=True)
    acc = clean_num(g("Accuracy", "50")) or "50"
    alt = clean_num(g("Altitude", ""), allow_neg=True)
    speed = clean_num(g("Speed", ""))
    heading = clean_num(g("Heading", ""))
    if not lat or not lon:
        sys.exit(0)
    print("|".join([lat, lon, acc, alt, speed, heading, "geoclue"]))
except Exception:
    sys.exit(0)
PY
}

read_modemmanager() {
  out=""
  if command -v mmcli >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      out=$(sudo -n mmcli -m any --location-get 2>/dev/null || true)
    else
      out=$(mmcli -m any --location-get 2>/dev/null || true)
    fi
  fi
  [ -n "$out" ] || return 0
  lat=$(printf '%s\n' "$out" | sed -n 's/.*latitude: *\([0-9.+-]*\).*/\1/p' | head -1)
  lon=$(printf '%s\n' "$out" | sed -n 's/.*longitude: *\([0-9.+-]*\).*/\1/p' | head -1)
  acc=$(printf '%s\n' "$out" | sed -n 's/.*accuracy: *\([0-9.+-]*\).*/\1/p' | head -1)
  alt=$(printf '%s\n' "$out" | sed -n 's/.*altitude: *\([0-9.+-]*\).*/\1/p' | head -1)
  [ -n "$lat" ] && [ -n "$lon" ] || return 0
  [ -n "$acc" ] || acc="25"
  echo "${lat}|${lon}|${acc}|${alt:-}|-|-|mm"
}

resolve_fix() {
  FIX_LIVE=0
  FIX_LAT=""
  FIX_LON=""
  FIX_ACC=""
  FIX_ALT=""
  FIX_SPEED=""
  FIX_BEARING=""
  FIX_SOURCE=""

  line=$(read_geoclue)
  if [ -z "$line" ]; then
    line=$(read_modemmanager)
  fi
  load_last_known
  now=$(date +%s)
  picked=$(pick_fix_from_line "$line" "$LAST_LAT" "$LAST_LON" "$LAST_ACC" "$LAST_TS" "$now" "$MAX_AGE" "$STALE_ACC" "$MIN_ACC" "$MAX_LIVE_ACC") || return 1

  OLDIFS=$IFS
  IFS='|'
  # shellcheck disable=SC2086
  set -- $picked
  IFS=$OLDIFS
  kind=$1
  FIX_LAT=$2
  FIX_LON=$3
  FIX_ACC=$4
  FIX_ALT=${5:-}
  FIX_SPEED=${6:-}
  FIX_BEARING=${7:-}
  FIX_SOURCE=${8:-}
  if [ "$kind" = "LIVE" ]; then
    FIX_LIVE=1
    # Persist only when this live fix does not degrade a better last-known.
    if should_update_last_known "$FIX_ACC" "$LAST_ACC" "$LAST_TS" "$now" "$MAX_AGE" "$MAX_LIVE_ACC"; then
      save_last_known "$FIX_LAT" "$FIX_LON" "$FIX_ACC" "$FIX_ALT" "$FIX_SPEED" "$FIX_BEARING" "$FIX_SOURCE"
    else
      log_rate skip_save "$LOG_IDLE_S" "skip save last-known (live acc=$FIX_ACC worse than stored acc=$LAST_ACC)"
    fi
  else
    FIX_LIVE=0
  fi
  return 0
}

# --- guest inject -----------------------------------------------------------

# Soft setup: enable location + test providers WITHOUT removing existing ones
# (remove thrashes last location and races concurrent injects).
ensure_guest_providers_soft() {
  sudo -n mkdir -p "$GDATA" 2>/dev/null || true
  cat <<'EOS' | sudo -n tee "$GDATA/gps-forward-setup.sh" >/dev/null
#!/system/bin/sh
settings put global development_settings_enabled 1
settings put secure mock_location 1
appops set com.android.shell android:mock_location allow 2>/dev/null
appops set 2000 android:mock_location allow 2>/dev/null
appops set 0 android:mock_location allow 2>/dev/null
cmd location set-location-enabled true 2>/dev/null
# Add if missing; ignore "already exists"
cmd location providers add-test-provider gps --supportsAltitude --supportsSpeed --supportsBearing --powerRequirement 1 2>/dev/null
cmd location providers add-test-provider network --requiresNetwork --supportsAltitude --powerRequirement 1 2>/dev/null
cmd location providers set-test-provider-enabled gps true 2>/dev/null
cmd location providers set-test-provider-enabled network true 2>/dev/null
echo GPS_FWD_SETUP_OK
EOS
  sudo -n chmod 755 "$GDATA/gps-forward-setup.sh" 2>/dev/null || true
  out=$(ws_soft /system/bin/sh /data/local/tmp/gps-forward-setup.sh)
  echo "$out" | grep -q GPS_FWD_SETUP_OK
}

# Hard recreate only after repeated inject failures.
ensure_guest_providers_hard() {
  sudo -n mkdir -p "$GDATA" 2>/dev/null || true
  cat <<'EOS' | sudo -n tee "$GDATA/gps-forward-setup-hard.sh" >/dev/null
#!/system/bin/sh
settings put global development_settings_enabled 1
settings put secure mock_location 1
appops set com.android.shell android:mock_location allow 2>/dev/null
appops set 2000 android:mock_location allow 2>/dev/null
appops set 0 android:mock_location allow 2>/dev/null
cmd location set-location-enabled true 2>/dev/null
cmd location providers remove-test-provider gps 2>/dev/null
cmd location providers remove-test-provider network 2>/dev/null
cmd location providers add-test-provider gps --supportsAltitude --supportsSpeed --supportsBearing --powerRequirement 1
cmd location providers add-test-provider network --requiresNetwork --supportsAltitude --powerRequirement 1
cmd location providers set-test-provider-enabled gps true
cmd location providers set-test-provider-enabled network true
echo GPS_FWD_SETUP_HARD_OK
EOS
  sudo -n chmod 755 "$GDATA/gps-forward-setup-hard.sh" 2>/dev/null || true
  out=$(ws_soft /system/bin/sh /data/local/tmp/gps-forward-setup-hard.sh)
  echo "$out" | grep -q GPS_FWD_SETUP_HARD_OK
}

inject_location() {
  lat="$1"
  lon="$2"
  acc="$3"
  nacc=$(awk -v a="$acc" 'BEGIN{ a=a+0; if (a < 30) a=30; printf "%.1f", a }')
  # Critical: waydroid shell parses argv itself. Flags like --location must come
  # after "--" or they are rejected (unrecognized arguments). Do NOT use
  # `waydroid shell sh -c "..."` — -c is also swallowed by the host CLI.
  # Prefer writing a guest script (same pattern as provider setup) for reliability.
  sudo -n mkdir -p "$GDATA" 2>/dev/null || true
  # shellcheck disable=SC2016
  cat <<EOS | sudo -n tee "$GDATA/gps-forward-inject.sh" >/dev/null
#!/system/bin/sh
cmd location providers set-test-provider-location gps --location ${lat},${lon} --accuracy ${acc}
gps_rc=\$?
cmd location providers set-test-provider-location network --location ${lat},${lon} --accuracy ${nacc}
net_rc=\$?
echo GPS_FWD_INJECT gps_rc=\$gps_rc net_rc=\$net_rc
[ "\$gps_rc" = "0" ]
EOS
  sudo -n chmod 755 "$GDATA/gps-forward-inject.sh" 2>/dev/null || true
  out=$(ws /system/bin/sh /data/local/tmp/gps-forward-inject.sh 2>&1) || true
  echo "$out" | grep -q 'GPS_FWD_INJECT gps_rc=0' || return 1
  return 0
}

fail_streak_get() {
  cat "$FAILFILE" 2>/dev/null || echo 0
}

fail_streak_set() {
  echo "$1" >"$FAILFILE"
}

# --- lifecycle --------------------------------------------------------------

stop_mock_if_running() {
  if command -v waydroid-mock-location >/dev/null 2>&1; then
    if waydroid-mock-location status 2>/dev/null | head -1 | grep -q RUNNING; then
      log "stopping waydroid-mock-location (same inject path)"
      waydroid-mock-location stop 2>/dev/null || true
    fi
  fi
}

self_path() {
  case "$0" in
    /*) echo "$0" ;;
    *) echo "$(CDPATH='' cd -- "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
  esac
}

write_runner() {
  self=$(self_path)
  runner="$RUNTIME/run-loop.sh"
  cat >"$runner" <<EOF
#!/bin/sh
# Generated by waydroid-gps-forward — do not edit.
echo \$\$ >"$PIDFILE"
export PATH="$PATH"
export HOME="$HOME"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}"
while true; do
  if systemctl is-active --quiet waydroid-gps-inject.service 2>/dev/null; then
    sleep 300   # root injector owns Waydroid location; stay idle
    continue
  fi
  "$self" once || true
  sleep $INTERVAL
done
EOF
  chmod +x "$runner"
  echo "$runner"
}

install_user_unit() {
  self=$(self_path)
  udir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$udir"
  runner=$(write_runner)
  cat >"$udir/$UNIT_NAME" <<EOF
[Unit]
Description=Waydroid host GPS forward (GeoClue / last-known → guest)
After=default.target
# Keep running; inject skips until Waydroid is fully up.

[Service]
Type=simple
ExecStart=$runner
Restart=always
RestartSec=3
# Inherit user session env for waydroid / dbus
Environment=PATH=%h/.local/bin:/usr/bin:/bin
Environment=HOME=%h

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable "$UNIT_NAME" 2>/dev/null || true
  log "installed user unit $udir/$UNIT_NAME"
}

start() {
  mkdir -p "$STATE_ROOT" "$RUNTIME"
  if root_inject_active; then
    echo "root waydroid-gps-inject.service is active — user loop not needed; disabling $UNIT_NAME"
    systemctl --user disable --now "$UNIT_NAME" 2>/dev/null || true
    return 0
  fi
  seed_last_known_if_missing
  stop_mock_if_running
  : >>"$LOGFILE"
  rm -f "$RUNTIME/setup.done" "$FAILFILE"

  install_user_unit
  runner=$(write_runner)

  if systemctl --user is-active "$UNIT_NAME" >/dev/null 2>&1; then
    systemctl --user restart "$UNIT_NAME" 2>/dev/null || true
  else
    # Prefer persistent unit; fall back to transient systemd-run
    if ! systemctl --user start "$UNIT_NAME" 2>/dev/null; then
      systemctl --user stop "$UNIT_NAME" 2>/dev/null || true
      systemctl --user reset-failed "$UNIT_NAME" 2>/dev/null || true
      systemd-run --user --unit="$UNIT_NAME" \
        --property=Type=simple \
        --property=Restart=always \
        --property=RestartSec=3 \
        "$runner" >/dev/null 2>&1 || {
        if command -v setsid >/dev/null 2>&1; then
          setsid -f "$runner" </dev/null >>"$LOGFILE" 2>&1
        else
          nohup "$runner" </dev/null >>"$LOGFILE" 2>&1 &
        fi
      }
    fi
  fi

  i=0
  while [ "$i" -lt 40 ]; do
    if is_running; then
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done

  if systemctl --user is-active "$UNIT_NAME" >/dev/null 2>&1; then
    main=$(systemctl --user show "$UNIT_NAME" -p MainPID --value 2>/dev/null || true)
    [ -n "$main" ] && [ "$main" != "0" ] && echo "$main" >"$PIDFILE"
  fi

  if ! is_running; then
    echo "Failed to start background loop" >&2
    return 1
  fi

  # Kick one cycle immediately
  once || true

  load_last_known
  notify "Waydroid GPS forward ON" "Auto host→guest\n${LAST_LAT},${LAST_LON}"
  echo "Started waydroid-gps-forward (pid=$(cat "$PIDFILE" 2>/dev/null || echo '?')) interval=${INTERVAL}s"
  echo "Last known: ${LAST_LAT},${LAST_LON} src=${LAST_SOURCE:-seed}"
  echo "Unit: $UNIT_NAME (enabled for login)"
  echo "Log: $LOGFILE"
}

stop() {
  systemctl --user stop "$UNIT_NAME" 2>/dev/null || true
  systemctl --user reset-failed "$UNIT_NAME" 2>/dev/null || true
  if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
      kill -- -"$pid" 2>/dev/null || true
    fi
    rm -f "$PIDFILE"
  fi
  if [ "${GPS_FWD_REMOVE_PROVIDERS:-0}" = "1" ] && guest_boot_ready; then
    ws_soft /system/bin/cmd location providers remove-test-provider gps
    ws_soft /system/bin/cmd location providers remove-test-provider network
  fi
  notify "Waydroid GPS forward OFF" "Stopped host→guest inject"
  echo "Stopped."
}

enable_autostart() {
  install_user_unit
  start
  echo "Enabled: will start with user session (WantedBy=default.target)."
}

disable_autostart() {
  stop
  systemctl --user disable "$UNIT_NAME" 2>/dev/null || true
  echo "Disabled user unit $UNIT_NAME."
}

status() {
  unit_active=0
  systemctl --user is-active "$UNIT_NAME" >/dev/null 2>&1 && unit_active=1
  unit_enabled=0
  systemctl --user is-enabled "$UNIT_NAME" >/dev/null 2>&1 && unit_enabled=1
  if is_running; then
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -z "$pid" ] && [ "$unit_active" = "1" ]; then
      pid=$(systemctl --user show "$UNIT_NAME" -p MainPID --value 2>/dev/null || true)
    fi
    echo "RUNNING pid=${pid:-?} interval=${INTERVAL}s unit_active=$unit_active unit_enabled=$unit_enabled"
  else
    echo "STOPPED unit_active=$unit_active unit_enabled=$unit_enabled"
  fi
  load_last_known
  now=$(date +%s)
  age=$((now - LAST_TS))
  echo "last_known: lat=$LAST_LAT lon=$LAST_LON acc=$LAST_ACC src=$LAST_SOURCE age_s=$age"
  if line=$(read_geoclue); [ -n "$line" ]; then
    echo "host_geoclue: $line"
  else
    echo "host_geoclue: (no fix right now)"
  fi
  if waydroid_session_running; then
    if guest_boot_ready; then
      echo "waydroid: Session RUNNING boot_completed=1"
    else
      echo "waydroid: Session RUNNING boot_completed=0 (inject paused)"
    fi
    ws_soft dumpsys location | grep -iE 'Location Setting|last location=Location|gps provider|network provider' | head -20 || true
  else
    echo "waydroid: Session not RUNNING"
  fi
  if [ -f "$LOGFILE" ]; then
    echo "log_tail:"
    tail -5 "$LOGFILE" 2>/dev/null || true
  fi
}

log_inject_ok() {
  msg="$*"
  h=$(printf '%s' "$msg" | cksum | awk '{print $1}')
  prev=$(cat "$INJECT_HASH" 2>/dev/null || true)
  if [ "$h" != "$prev" ]; then
    echo "$h" >"$INJECT_HASH" 2>/dev/null || true
    log "$msg"
  else
    # Same fix: rate-limit success spam
    log_rate inject_ok_same "$LOG_IDLE_S" "$msg"
  fi
}

once() {
  if root_inject_active; then
    log_rate root_active "$LOG_IDLE_S" "once: root waydroid-gps-inject.service active — user loop idle"
    return 0
  fi
  seed_last_known_if_missing

  # Always refresh last-known from host when possible (even if guest down).
  if ! resolve_fix; then
    log_rate nofix "$LOG_IDLE_S" "once: no fix (host and last-known empty)"
    return 0
  fi

  if ! waydroid_session_running; then
    log_rate sess_down "$LOG_IDLE_S" "once: session not RUNNING — host fix kept last_known live=$FIX_LIVE src=$FIX_SOURCE"
    return 0
  fi

  if ! guest_boot_ready; then
    log_rate boot_wait "$LOG_IDLE_S" "once: guest not boot_completed — skip inject live=$FIX_LIVE src=$FIX_SOURCE"
    return 0
  fi

  # Soft setup once per boot window
  if [ ! -f "$RUNTIME/setup.done" ]; then
    if ensure_guest_providers_soft; then
      touch "$RUNTIME/setup.done" 2>/dev/null || true
      log "once: guest providers soft-setup ok"
    else
      log_rate setup_pend 30 "once: guest providers soft-setup pending"
    fi
  fi

  if inject_location "$FIX_LAT" "$FIX_LON" "$FIX_ACC"; then
    fail_streak_set 0
    log_inject_ok "inject ok live=$FIX_LIVE src=$FIX_SOURCE lat=$FIX_LAT lon=$FIX_LON acc=$FIX_ACC"
    return 0
  fi

  # Soft re-setup then retry
  ensure_guest_providers_soft || true
  if inject_location "$FIX_LAT" "$FIX_LON" "$FIX_ACC"; then
    fail_streak_set 0
    log_inject_ok "inject ok (after soft setup) live=$FIX_LIVE src=$FIX_SOURCE lat=$FIX_LAT lon=$FIX_LON acc=$FIX_ACC"
    return 0
  fi

  streak=$(fail_streak_get)
  streak=$((streak + 1))
  fail_streak_set "$streak"
  log "inject failed streak=$streak live=$FIX_LIVE src=$FIX_SOURCE"

  # Hard recreate at streak 3, 6, 9… — not every cycle (avoids provider thrash).
  if [ "$streak" -ge 3 ] && [ $((streak % 3)) -eq 0 ]; then
    log "inject hard-recreate providers (streak=$streak)"
    ensure_guest_providers_hard || true
    if inject_location "$FIX_LAT" "$FIX_LON" "$FIX_ACC"; then
      fail_streak_set 0
      touch "$RUNTIME/setup.done" 2>/dev/null || true
      log_inject_ok "inject ok (after hard setup) live=$FIX_LIVE src=$FIX_SOURCE lat=$FIX_LAT lon=$FIX_LON acc=$FIX_ACC"
      return 0
    fi
  fi
  return 0
}

selftest() {
  # Pure logic tests — no Waydroid required. Must exercise real functions.
  fail=0
  echo "selftest: valid_coords"
  if ! valid_coords "59.95" "11.01"; then echo "FAIL valid good"; fail=1; fi
  if valid_coords "0" "0"; then echo "FAIL null island"; fail=1; fi
  if valid_coords "" "11"; then echo "FAIL empty"; fail=1; fi
  if valid_coords "99" "0"; then echo "FAIL lat range"; fail=1; fi

  echo "selftest: pick_fix live line"
  out=$(pick_fix_from_line "59.1|10.2|12||||geoclue" "1" "2" "50" 0 100 86400 80 8 500) || { echo "FAIL pick live"; fail=1; out=""; }
  case "$out" in
    LIVE\|59.1\|10.2\|*) echo "ok pick live: $out" ;;
    *) echo "FAIL pick live got: $out"; fail=1 ;;
  esac

  echo "selftest: pick_fix last-known when line empty"
  out=$(pick_fix_from_line "" "59.9" "10.9" "15" 90 100 86400 80 8 500) || { echo "FAIL pick last"; fail=1; out=""; }
  case "$out" in
    LAST\|59.9\|10.9\|*) echo "ok pick last: $out" ;;
    *) echo "FAIL pick last got: $out"; fail=1 ;;
  esac

  echo "selftest: pick_fix prefers last-known when live is coarse"
  # live acc 2000m (clamped), last-known 30m → prefer LAST when max_live_acc=500
  out=$(pick_fix_from_line "59.95|11.01|25000||||geoclue" "59.9" "10.9" "25" 90 100 86400 80 8 500) || { echo "FAIL pick coarse"; fail=1; out=""; }
  case "$out" in
    LAST\|59.9\|10.9\|*) echo "ok prefer last over coarse live: $out" ;;
    *) echo "FAIL prefer last got: $out"; fail=1 ;;
  esac

  echo "selftest: pick_fix prefers stale last-known over city-level live"
  # last_ts=0, now=100000, max_age=100 → stale; live 25000m must not win
  out=$(pick_fix_from_line "59.95|11.01|25000||||geoclue" "59.9" "10.9" "25" 0 100000 100 80 8 500) || { echo "FAIL stale+coarse"; fail=1; out=""; }
  case "$out" in
    LAST\|59.9\|10.9\|*) echo "ok prefer stale last over city live: $out" ;;
    *) echo "FAIL stale+coarse got: $out"; fail=1 ;;
  esac

  echo "selftest: pick_fix rejects bad line and empty last"
  if pick_fix_from_line "bad|line" "" "" "10" 0 100 86400 80 8 500 2>/dev/null; then
    echo "FAIL should reject"; fail=1
  else
    echo "ok reject empty"
  fi

  echo "selftest: save/load last-known (real files under STATE_ROOT)"
  # Use a nested temp under STATE_ROOT without pointing HOME at scratch permanently
  tdir="$STATE_ROOT/selftest-$$"
  mkdir -p "$tdir"
  OLD_LAST="$LASTFILE"
  LASTFILE="$tdir/last-known.env"
  save_last_known "58.1" "7.9" "25" "" "" "" "selftest"
  load_last_known
  if [ "$LAST_LAT" = "58.1" ] && [ "$LAST_LON" = "7.9" ] && [ "$LAST_SOURCE" = "selftest" ]; then
    echo "ok save/load"
  else
    echo "FAIL save/load LAT=$LAST_LAT LON=$LAST_LON SRC=$LAST_SOURCE"
    fail=1
  fi

  echo "selftest: should_update_last_known rejects coarse over good"
  now=1000
  if should_update_last_known 2000 30 900 "$now" 86400 500; then
    echo "FAIL should refuse coarse 2000 over good 30"; fail=1
  else
    echo "ok refuse coarse over good"
  fi
  if ! should_update_last_known 20 30 900 "$now" 86400 500; then
    echo "FAIL should accept better 20 over 30"; fail=1
  else
    echo "ok accept better accuracy"
  fi
  if ! should_update_last_known 40 "" 0 "$now" 86400 500; then
    echo "FAIL should accept first fix when no old"; fail=1
  else
    echo "ok first fix when empty old"
  fi
  # Stale old + coarse new → refuse
  if should_update_last_known 2000 30 0 "$now" 100 500; then
    echo "FAIL stale+coarse should refuse"; fail=1
  else
    echo "ok refuse stale reseal with coarse"
  fi
  # Persist path: good last-known must not be overwritten by coarse live save
  save_last_known "59.9" "10.9" "25" "" "" "" "good"
  load_last_known
  good_acc=$LAST_ACC
  if should_update_last_known 2000 "$LAST_ACC" "$LAST_TS" "$(date +%s)" 86400 500; then
    echo "FAIL persist gate would allow coarse overwrite"; fail=1
  else
    # Would-be save skipped — file still good
    load_last_known
    if [ "$LAST_ACC" = "25" ] || [ "$LAST_ACC" = "25.0" ] || [ "$LAST_ACC" = "$good_acc" ]; then
      echo "ok last-known file stays good (acc=$LAST_ACC)"
    else
      echo "FAIL last-known degraded acc=$LAST_ACC"; fail=1
    fi
  fi

  LASTFILE="$OLD_LAST"
  rm -rf "$tdir"

  echo "selftest: clamp_acc"
  c=$(clamp_acc 3)
  case "$c" in
    8.0|8) echo "ok clamp min $c" ;;
    *) echo "FAIL clamp min $c"; fail=1 ;;
  esac

  if [ "$fail" -eq 0 ]; then
    echo "ALL_GPS_FWD_SELFTESTS_OK"
    return 0
  fi
  echo "SELFTEST_FAILED"
  return 1
}

once_loop() {
  # Long-running loop used as ExecStart when a static unit points here.
  mkdir -p "$STATE_ROOT" "$RUNTIME"
  echo $$ >"$PIDFILE"
  seed_last_known_if_missing
  while true; do
    once || true
    sleep "$INTERVAL"
  done
}

# Force last-known to explicit coords (or SEED_* defaults). Bypasses coarse-host rot.
seed_cmd() {
  lat="${1:-$SEED_LAT}"
  lon="${2:-$SEED_LON}"
  acc="${3:-$SEED_ACC}"
  if ! valid_coords "$lat" "$lon"; then
    echo "Invalid lat/lon: $lat $lon" >&2
    return 1
  fi
  acc=$(clamp_acc "$acc")
  mkdir -p "$STATE_ROOT"
  save_last_known "$lat" "$lon" "$acc" "" "" "" "seed-cli"
  load_last_known
  echo "Seeded last-known: lat=$LAST_LAT lon=$LAST_LON acc=$LAST_ACC src=$LAST_SOURCE"
  log "seed-cli lat=$LAST_LAT lon=$LAST_LON acc=$LAST_ACC"
}

# Capture current host GeoClue/MM if accuracy is good enough for last-known.
# Flags: --force  save even if coarser than stored (still rejects city-level unless --force-coarse)
seed_from_host() {
  force=0
  force_coarse=0
  for a in "$@"; do
    case "$a" in
      --force) force=1 ;;
      --force-coarse) force=1; force_coarse=1 ;;
    esac
  done
  mkdir -p "$STATE_ROOT" "$RUNTIME"
  load_last_known
  line=$(read_geoclue)
  if [ -z "$line" ]; then
    line=$(read_modemmanager)
  fi
  if [ -z "$line" ]; then
    echo "No host fix available (GeoClue/MM empty)" >&2
    return 1
  fi
  lat=$(printf '%s' "$line" | cut -d'|' -f1)
  lon=$(printf '%s' "$line" | cut -d'|' -f2)
  acc=$(printf '%s' "$line" | cut -d'|' -f3)
  src=$(printf '%s' "$line" | cut -d'|' -f7)
  [ -n "$src" ] || src=host
  if ! valid_coords "$lat" "$lon"; then
    echo "Host line not valid coords: $line" >&2
    return 1
  fi
  # Reject city-level unless --force-coarse
  if [ "$force_coarse" != "1" ]; then
    if ! awk -v a="$acc" -v m="$MAX_LIVE_ACC" 'BEGIN{ exit !((a+0) <= (m+0)) }'; then
      echo "Host fix too coarse (acc=$acc > max $MAX_LIVE_ACC); not seeding. Use: seed LAT LON ACC or seed-from-host --force-coarse" >&2
      echo "host_line: $line"
      return 1
    fi
  fi
  acc=$(clamp_acc "$acc")
  if [ "$force" = "1" ] || should_update_last_known "$acc" "$LAST_ACC" "$LAST_TS" "$(date +%s)" "$MAX_AGE" "$MAX_LIVE_ACC"; then
    save_last_known "$lat" "$lon" "$acc" "" "" "" "seed-host-$src"
    echo "Seeded from host: lat=$lat lon=$lon acc=$acc src=$src force=$force"
  else
    echo "Host fix not better than stored last-known (host acc=$acc stored=$LAST_ACC); kept existing (pass --force to overwrite)"
  fi
  load_last_known
  echo "last_known: lat=$LAST_LAT lon=$LAST_LON acc=$LAST_ACC src=$LAST_SOURCE"
  log "seed-from-host lat=$LAST_LAT lon=$LAST_LON acc=$LAST_ACC force=$force"
}

cmd="${1:-status}"
shift $(( $# > 0 ? 1 : 0 )) || true

case "$cmd" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  once) once ;;
  once-loop) once_loop ;;
  enable) enable_autostart ;;
  disable) disable_autostart ;;
  selftest) selftest ;;
  seed) seed_cmd "$@" ;;
  seed-from-host) seed_from_host ;;
  toggle)
    if is_running; then stop; else start; fi
    ;;
  *)
    echo "usage: $0 {start|stop|status|once|once-loop|enable|disable|toggle|selftest|seed|seed-from-host}" >&2
    exit 2
    ;;
esac
