#!/bin/sh
# Toggle continuous Bluetooth + Soft HCI + host-bridge logging for field tests
# (e.g. Tesla near the car). Safe to launch from Phosh app drawer.
#
# Start: creates ~/bt-log-sessions/YYYYMMDD-HHMMSS/ and tails journals/logcat
# Stop:  kills loggers, writes STOPPED marker + quick summary
set -eu

SESSIONS_ROOT="${BT_LOG_SESSIONS_ROOT:-$HOME/bt-log-sessions}"
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/waydroid-bt-log-session"
PIDFILE="$STATE_DIR/pids"
ACTIVE="$STATE_DIR/active-dir"
LOCK="$STATE_DIR/lock"

mkdir -p "$STATE_DIR" "$SESSIONS_ROOT"

notify() {
  title="$1"
  body="$2"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -a "BT Log" -i bluetooth "$title" "$body" 2>/dev/null || true
  fi
  logger -t bt-log-session "$title: $body" 2>/dev/null || true
}

is_running() {
  [ -f "$PIDFILE" ] || return 1
  while read -r pid; do
    [ -n "$pid" ] || continue
    if kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  done <"$PIDFILE"
  return 1
}

stop_session() {
  dir=""
  [ -f "$ACTIVE" ] && dir=$(cat "$ACTIVE" 2>/dev/null || true)
  # Stop systemd supervisor first (if we used it to survive SSH logout)
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user stop waydroid-bt-log-ready.service 2>/dev/null || true
    systemctl --user reset-failed waydroid-bt-log-ready.service 2>/dev/null || true
  fi
  if [ -f "$PIDFILE" ]; then
    while read -r pid; do
      [ -n "$pid" ] || continue
      kill "$pid" 2>/dev/null || true
      # child process groups from setsid
      kill -- -"$pid" 2>/dev/null || true
    done <"$PIDFILE"
    rm -f "$PIDFILE"
  fi
  # stray logcat/journalctl we own
  pkill -f 'bt-log-session-helper' 2>/dev/null || true

  if [ -n "$dir" ] && [ -d "$dir" ]; then
    {
      echo "stopped: $(date -Is)"
      echo "hostname: $(hostname 2>/dev/null || true)"
      command -v bluetoothctl >/dev/null && bluetoothctl devices 2>/dev/null || true
      command -v waydroid >/dev/null && waydroid status 2>/dev/null || true
    } >"$dir/session-end.txt" 2>/dev/null || true
    # final snapshots
    journalctl -u waydroid-bt-host -n 400 --no-pager >"$dir/host-bridge-tail.txt" 2>/dev/null || true
    journalctl -u bluetooth -n 200 --no-pager >"$dir/bluetoothd-tail.txt" 2>/dev/null || true
    # Snapshot already in follow files; leave a size summary
    wc -c "$dir"/guest-logcat*.log "$dir"/*follow.log 2>/dev/null >"$dir/sizes.txt" || true
    echo "stopped $(date -Is)" >"$dir/STOPPED"
    sz=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
    notify "BT logging stopped" "Saved: $dir ($sz)"
    echo "Stopped. Logs in: $dir"
  else
    notify "BT logging stopped" "No active session dir"
    echo "Stopped (no active session dir)."
  fi
  rm -f "$ACTIVE"
}

start_session() {
  if is_running; then
    notify "BT logging already on" "Tap again to stop, or run: $0 stop"
    echo "Already running. Use: $0 stop"
    exit 0
  fi

  # When started over SSH, plain background jobs die on SIGHUP even with setsid
  # (process-group / session quirks). Hand off once to a user systemd unit that
  # keeps a supervisor (`sleep infinity`) so loggers survive logout. Phosh icon
  # and in-unit re-entry set BT_LOG_UNDER_SYSTEMD=1 and skip this wrap.
  if [ "${BT_LOG_UNDER_SYSTEMD:-0}" != "1" ] \
    && command -v systemd-run >/dev/null 2>&1 \
    && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    systemctl --user stop waydroid-bt-log-ready.service 2>/dev/null || true
    systemctl --user reset-failed waydroid-bt-log-ready.service 2>/dev/null || true
    # Resolve absolute path so the unit does not depend on PATH.
    self=$(command -v "$0" 2>/dev/null || echo "$0")
    case "$self" in
      /*) ;;
      *) self="$PWD/$self" ;;
    esac
    if [ ! -x "$self" ] && [ -x "$HOME/.local/bin/bt-log-session" ]; then
      self="$HOME/.local/bin/bt-log-session"
    fi
    systemd-run --user --unit=waydroid-bt-log-ready.service \
      --property=Type=simple \
      --property=Restart=on-failure \
      --property=RestartSec=2 \
      /bin/sh -c "
        export BT_LOG_UNDER_SYSTEMD=1
        export PATH=\"$HOME/.local/bin:/usr/bin:/bin\"
        export XDG_RUNTIME_DIR=\"${XDG_RUNTIME_DIR}\"
        export HOME=\"${HOME}\"
        export DBUS_SESSION_BUS_ADDRESS=\"${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}\"
        \"$self\" start
        exec sleep infinity
      " >/dev/null
    # Wait briefly for workers to come up under the unit.
    i=0
    while [ "$i" -lt 30 ]; do
      if is_running; then
        dir=""
        [ -f "$ACTIVE" ] && dir=$(cat "$ACTIVE" 2>/dev/null || true)
        notify "BT logging STARTED" "${dir:-session}\nNear car: open Tesla app, try unlock.\nTap icon again to stop."
        echo "Started logging → ${dir:-under waydroid-bt-log-ready.service}"
        echo "Tap the icon again (or: $0 stop) when done."
        exit 0
      fi
      i=$((i + 1))
      sleep 0.1
    done
    echo "warning: systemd supervisor started but workers not yet visible; check: systemctl --user status waydroid-bt-log-ready.service" >&2
    exit 1
  fi

  ts=$(date +%Y%m%d-%H%M%S)
  dir="$SESSIONS_ROOT/session-$ts"
  mkdir -p "$dir"
  echo "$dir" >"$ACTIVE"
  : >"$PIDFILE"

  {
    echo "started: $(date -Is)"
    echo "user: $(id)"
    echo "uname: $(uname -a)"
    cat /etc/os-release 2>/dev/null || true
    echo "--- bluetoothctl show ---"
    bluetoothctl show 2>/dev/null || true
    echo "--- bluetoothctl devices ---"
    bluetoothctl devices 2>/dev/null || true
    echo "--- waydroid status ---"
    waydroid status 2>/dev/null || true
    echo "--- soft hci process ---"
    pgrep -af 'android.hardware.bluetooth@1.0-service.waydroid' 2>/dev/null || true
    echo "--- waydroid-bt-host ---"
    systemctl is-active waydroid-bt-host 2>/dev/null || true
    pgrep -af waydroid-bt-host 2>/dev/null || true
  } >"$dir/session-start.txt" 2>&1 || true

  # Detach loggers so a remote SSH start survives logout.
  # Plain `setsid cmd &` fails when the shell background job is already a
  # process-group leader (setsid EPERM) — workers stay in the SSH session and
  # die on SIGHUP. util-linux `setsid -f` forks first. Child writes its pid
  # (shell $! is not the worker when using setsid -f without &).
  spawn_detached() {
    # usage: spawn_detached <logfile> <command...>
    _out="$1"
    shift
    _pf="$STATE_DIR/spawn-pid.$$"
    rm -f "$_pf"
    if command -v setsid >/dev/null 2>&1; then
      setsid -f sh -c 'echo $$ >"$1"; shift; out="$1"; shift; exec "$@" >"$out" 2>&1' \
        sh "$_pf" "$_out" "$@" </dev/null
    else
      nohup sh -c 'echo $$ >"$1"; shift; out="$1"; shift; exec "$@" >"$out" 2>&1' \
        sh "$_pf" "$_out" "$@" </dev/null &
    fi
    _i=0
    while [ ! -s "$_pf" ] && [ "$_i" -lt 40 ]; do
      sleep 0.05
      _i=$((_i + 1))
    done
    if [ -s "$_pf" ]; then
      cat "$_pf" >>"$PIDFILE"
    fi
    rm -f "$_pf"
  }

  spawn_detached_sh() {
    # usage: spawn_detached_sh <logfile> <shell-script-body> [args for $1,$2,...]
    _out="$1"
    _body="$2"
    shift 2
    _pf="$STATE_DIR/spawn-pid.$$"
    rm -f "$_pf"
    if command -v setsid >/dev/null 2>&1; then
      setsid -f sh -c 'echo $$ >"$1"; shift; out="$1"; shift; body="$1"; shift; eval "$body" >"$out" 2>&1' \
        sh "$_pf" "$_out" "$_body" "$@" </dev/null
    else
      nohup sh -c 'echo $$ >"$1"; shift; out="$1"; shift; body="$1"; shift; eval "$body" >"$out" 2>&1' \
        sh "$_pf" "$_out" "$_body" "$@" </dev/null &
    fi
    _i=0
    while [ ! -s "$_pf" ] && [ "$_i" -lt 40 ]; do
      sleep 0.05
      _i=$((_i + 1))
    done
    if [ -s "$_pf" ]; then
      cat "$_pf" >>"$PIDFILE"
    fi
    rm -f "$_pf"
  }

  # Continuous host bridge log
  spawn_detached "$dir/waydroid-bt-host.follow.log" \
    journalctl -u waydroid-bt-host -f -o short-iso --no-pager

  # Continuous bluetoothd log
  spawn_detached "$dir/bluetoothd.follow.log" \
    journalctl -u bluetooth -f -o short-iso --no-pager

  # Kernel / hci messages (best effort)
  spawn_detached_sh "$dir/kernel-bt.follow.log" \
    'journalctl -k -f -o short-iso --no-pager 2>/dev/null | grep -iE "bluetooth|hci|bluez" --line-buffered'

  # Guest Android logcat (full stream — Tesla tags are unknown; do not filter).
  # waydroid shell needs root; "waydroid logcat" streams guest logcat.
  # $1 = session dir
  spawn_detached_sh /dev/null \
    'dir="$1"
     if command -v sudo >/dev/null && sudo -n true >/dev/null 2>&1; then
       sudo -n waydroid logcat 2>>"$dir/guest-logcat.err.log" \
         | tee "$dir/guest-logcat.follow.log" \
         | grep -iE "Soft HCI|bt_hci|bluetooth|Tesla|GATT|BLE|bt_stack|IBluetooth|HCI|Bond|scan|connect" \
         >"$dir/guest-logcat-btish.follow.log" 2>/dev/null || true
     else
       echo "need passwordless sudo for waydroid logcat" >"$dir/guest-logcat.follow.log"
       sleep 3600
     fi' \
    "$dir"

  # Optional: btmon if present (verbose HCI on host — large files)
  if command -v btmon >/dev/null 2>&1; then
    if [ "${BT_LOG_BTMON:-0}" = "1" ]; then
      spawn_detached "$dir/btmon.txt" btmon -w "$dir/btmon.pcap"
    fi
  fi

  # Heartbeat so we know the session stayed up
  spawn_detached_sh /dev/null \
    'while true; do date -Is >>"$1/heartbeat.txt"; sleep 30; done' \
    "$dir"

  notify "BT logging STARTED" "$dir\nNear car: open Tesla app, try unlock.\nTap icon again to stop."
  echo "Started logging → $dir"
  echo "Tap the icon again (or: $0 stop) when done."
}

cmd="${1:-toggle}"
case "$cmd" in
  start) start_session ;;
  stop) stop_session ;;
  status)
    if is_running; then
      echo "RUNNING"
      [ -f "$ACTIVE" ] && echo "dir=$(cat "$ACTIVE")"
      cat "$PIDFILE" 2>/dev/null || true
    else
      echo "STOPPED"
    fi
    ;;
  toggle)
    if is_running; then
      stop_session
    else
      start_session
    fi
    ;;
  *)
    echo "usage: $0 {toggle|start|stop|status}" >&2
    exit 2
    ;;
esac
