#!/bin/sh
# Fixed mock coordinates for Waydroid (override MOCK_LAT/LON/ACC).
# For live host GPS, prefer waydroid-gps-forward (stops this script if both used).
set -eu
LAT="${MOCK_LAT:-59.91}"
LON="${MOCK_LON:-10.75}"
ACC="${MOCK_ACC:-12}"
STATE="${XDG_RUNTIME_DIR:-/tmp}/waydroid-mock-location"
PIDFILE="$STATE/loop.pid"
GDATA="${HOME}/.local/share/waydroid/data/local/tmp"

notify() {
  command -v notify-send >/dev/null 2>&1 && notify-send -a "Mock Location" -i find-location "$1" "$2" 2>/dev/null || true
}
ws() { sudo -n waydroid shell "$@"; }

write_guest() {
  sudo -n mkdir -p "$GDATA"
  sudo -n tee "$GDATA/mock-location-once.sh" >/dev/null <<EOS
#!/system/bin/sh
LAT=$LAT
LON=$LON
ACC=$ACC
settings put global development_settings_enabled 1
settings put secure mock_location 1
appops set com.android.shell android:mock_location allow 2>/dev/null
appops set 2000 android:mock_location allow 2>/dev/null
appops set 0 android:mock_location allow 2>/dev/null
cmd location set-location-enabled true
cmd location providers remove-test-provider gps 2>/dev/null
cmd location providers remove-test-provider network 2>/dev/null
cmd location providers add-test-provider gps --supportsAltitude --supportsSpeed --supportsBearing --powerRequirement 1
cmd location providers add-test-provider network --requiresNetwork --supportsAltitude --powerRequirement 1
cmd location providers set-test-provider-enabled gps true
cmd location providers set-test-provider-enabled network true
cmd location providers set-test-provider-location gps --location \${LAT},\${LON} --accuracy \${ACC}
cmd location providers set-test-provider-location network --location \${LAT},\${LON} --accuracy 50
echo MOCK_OK lat=\$LAT lon=\$LON
EOS
  sudo -n chmod 755 "$GDATA/mock-location-once.sh"
}

is_running() {
  [ -f "$PIDFILE" ] || return 1
  kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

start() {
  mkdir -p "$STATE"
  if is_running; then
    notify "Mock location already on" "$LAT,$LON"
    echo "Already running"; return 0
  fi
  write_guest
  ws /system/bin/sh /data/local/tmp/mock-location-once.sh || true
  (
    while true; do
      ws /system/bin/cmd location providers set-test-provider-location gps --location "${LAT},${LON}" --accuracy "$ACC" >/dev/null 2>&1 || true
      ws /system/bin/cmd location providers set-test-provider-location network --location "${LAT},${LON}" --accuracy 50 >/dev/null 2>&1 || true
      sleep 2
    done
  ) &
  echo $! >"$PIDFILE"
  notify "Mock location ON" "$LAT, $LON"
  echo "Mock location started: $LAT,$LON"
}

stop() {
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -f "$PIDFILE"
  ws /system/bin/cmd location providers remove-test-provider gps >/dev/null 2>&1 || true
  ws /system/bin/cmd location providers remove-test-provider network >/dev/null 2>&1 || true
  notify "Mock location OFF" "Test providers removed"
  echo "Mock location stopped"
}

status() {
  if is_running; then echo "RUNNING pid=$(cat "$PIDFILE") lat=$LAT lon=$LON"
  else echo "STOPPED"; fi
  ws /system/bin/dumpsys location 2>/dev/null | grep -iE 'Location Setting|last location=Location' | head -12 || true
}

case "${1:-toggle}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  toggle) if is_running; then stop; else start; fi ;;
  *) echo "usage: $0 {toggle|start|stop|status}"; exit 2 ;;
esac
