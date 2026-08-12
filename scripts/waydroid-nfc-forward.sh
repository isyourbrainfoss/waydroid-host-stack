#!/bin/sh
# Forward host NFC tag discoveries into Waydroid (GPS-forwarder style).
#
# Host owns the PN553/NCI radio. This is NOT a Soft NFC HAL / dual-master NCI
# stack — it reads tags on the host (neard / libnfc / fixture / last-tag) and
# delivers a discovery into the guest via:
#   1) /data/local/tmp/nfc-forward-last.txt  (stable observation)
#   2) broadcast com.waydroid.nfc.FORWARD   (apps can listen)
#   3) am start VIEW / NDEF_DISCOVERED for URI payloads when resolvable
#
# Usage:
#   waydroid-nfc-forward start|stop|status|toggle|once|enable|disable|selftest
#   waydroid-nfc-forward push <type> <payload> [uid]
#   waydroid-nfc-forward once-loop
#
# Env:
#   NFC_FWD_INTERVAL   poll seconds (default 2)
#   NFC_FWD_MAX_AGE    last-tag max age before STALE (default 86400)
#   NFC_FWD_FIXTURE    path to fixture tag line file (uid|type|payload|source)
#   NFC_FWD_LOG_IDLE_S rate-limit idle logs (default 60)
#   NFC_FWD_HOST_STACK auto|neard|libnfc|none  (default auto)
set -eu

INTERVAL="${NFC_FWD_INTERVAL:-2}"
MAX_AGE="${NFC_FWD_MAX_AGE:-86400}"
LOG_IDLE_S="${NFC_FWD_LOG_IDLE_S:-60}"
HOST_STACK="${NFC_FWD_HOST_STACK:-auto}"

STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/waydroid-nfc-forward"
RUNTIME="${XDG_RUNTIME_DIR:-/tmp}/waydroid-nfc-forward"
PIDFILE="$RUNTIME/loop.pid"
LOGFILE="$RUNTIME/forward.log"
LASTFILE="$STATE_ROOT/last-tag.env"
FIXTURE="${NFC_FWD_FIXTURE:-$STATE_ROOT/fixture.tag}"
PUSHFILE="$STATE_ROOT/push.tag"
DELIVERED="$RUNTIME/last-delivered.hash"
FAILFILE="$RUNTIME/deliver-fail-streak"
GDATA="${HOME}/.local/share/waydroid/data/local/tmp"
UNIT_NAME="waydroid-nfc-forward.service"

mkdir -p "$STATE_ROOT" "$RUNTIME"

notify() {
  title="$1"
  body="$2"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -a "Waydroid NFC" -i network-wireless "$title" "$body" 2>/dev/null || true
  fi
  logger -t waydroid-nfc-forward "$title: $body" 2>/dev/null || true
}

log() {
  echo "$(date -Is 2>/dev/null || date) $*" >>"$LOGFILE" 2>/dev/null || true
}

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

# --- pure helpers (selftest) ------------------------------------------------

valid_uid() {
  uid="$1"
  [ -n "$uid" ] || return 1
  # hex UID or synthetic alphanumeric id, 2–32 chars
  echo "$uid" | grep -Eq '^[0-9A-Fa-f]{2,32}$|^[A-Za-z0-9_-]{2,64}$'
}

valid_type() {
  case "$1" in
    uri|text|raw|unknown) return 0 ;;
    *) return 1 ;;
  esac
}

# Normalize / validate a pipe-separated tag line:
#   uid|type|payload|source
# Prints cleaned line or fails.
parse_tag_line() {
  line="$1"
  [ -n "$line" ] || return 1
  OLDIFS=$IFS
  IFS='|'
  # shellcheck disable=SC2086
  set -- $line
  IFS=$OLDIFS
  uid=${1:-}
  typ=${2:-unknown}
  payload=${3:-}
  source=${4:-host}
  valid_uid "$uid" || return 1
  valid_type "$typ" || typ=unknown
  # payload required for uri/text; raw/unknown may be empty
  case "$typ" in
    uri|text)
      [ -n "$payload" ] || return 1
      ;;
  esac
  # strip CR and pipe from payload fields
  payload=$(printf '%s' "$payload" | tr -d '\r\n|')
  source=$(printf '%s' "$source" | tr -d '\r\n|')
  echo "${uid}|${typ}|${payload}|${source}"
}

# Classify payload string into type (uri|text).
classify_payload() {
  p="$1"
  case "$p" in
    http://*|https://*|tel:*|mailto:*|nfc:*)
      echo uri
      ;;
    *)
      echo text
      ;;
  esac
}

# Pure: pick live line or fall back to last-tag args.
# Usage: pick_tag_from_line "uid|type|payload|src" last_uid last_type last_payload last_source last_ts now max_age
# Prints: LIVE|uid|type|payload|source  OR  LAST|...  OR  LAST-STALE|...
pick_tag_from_line() {
  line="$1"
  last_uid="$2"
  last_type="$3"
  last_payload="$4"
  last_source="$5"
  last_ts="$6"
  now="$7"
  max_age="$8"

  if [ -n "$line" ]; then
    if cleaned=$(parse_tag_line "$line"); then
      OLDIFS=$IFS
      IFS='|'
      # shellcheck disable=SC2086
      set -- $cleaned
      IFS=$OLDIFS
      echo "LIVE|$1|$2|$3|$4"
      return 0
    fi
  fi
  if ! valid_uid "$last_uid"; then
    return 1
  fi
  typ=${last_type:-unknown}
  valid_type "$typ" || typ=unknown
  age=$((now - last_ts))
  if [ "$age" -gt "$max_age" ]; then
    echo "LAST-STALE|${last_uid}|${typ}|${last_payload}|${last_source:-last-tag}"
  else
    echo "LAST|${last_uid}|${typ}|${last_payload}|${last_source:-last-tag}"
  fi
  return 0
}

# Simple NDEF text record payload (UTF-8, status byte 0x02 = en).
# Input: plain text. Output: hex bytes of NDEF text payload (no full TLV).
ndef_text_payload_hex() {
  text="$1"
  # status = 0x02 (UTF-8, lang length 2), lang "en"
  printf '02'
  printf '%s' "en" | od -An -tx1 | tr -d ' \n'
  printf '%s' "$text" | od -An -tx1 | tr -d ' \n'
  echo
}

# URI identifier code 0x00 = no prepending; full URI in body.
ndef_uri_payload_hex() {
  uri="$1"
  printf '00'
  printf '%s' "$uri" | od -An -tx1 | tr -d ' \n'
  echo
}

tag_hash() {
  uid="$1"
  typ="$2"
  payload="$3"
  printf '%s|%s|%s' "$uid" "$typ" "$payload" | cksum | awk '{print $1}'
}

# --- last-tag persistence ---------------------------------------------------

# POSIX single-quote for KEY='value' env lines (spaces/semicolons safe).
nfc_sh_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Load KEY='…' lines without `source` (avoids bare PAYLOAD=hello world exec).
# Accepts single-quoted values (current format) or legacy bare tokens without
# spaces/metacharacters. Uses _kvline so we never clobber caller `line`.
load_last_tag() {
  LAST_UID=""
  LAST_TYPE=""
  LAST_PAYLOAD=""
  LAST_SOURCE=""
  LAST_TS=0
  if [ ! -f "$LASTFILE" ]; then
    return 0
  fi
  while IFS= read -r _kvline || [ -n "$_kvline" ]; do
    case "$_kvline" in
      ''|\#*) continue ;;
      TAG_UID=*|TYPE=*|PAYLOAD=*|SOURCE=*|TS=*)
        key=${_kvline%%=*}
        raw=${_kvline#*=}
        val=""
        case "$raw" in
          \'*)
            # eval only the RHS which we wrote as a single-quoted string
            eval "val=$raw"
            ;;
          *[\'\"\$\`\\\;\|\&\<\>\ \(\)\{\}\[\]\!\#]*)
            # bare value with shell metachar / space — refuse
            val=""
            ;;
          *)
            # legacy bare token or digits (no spaces/meta)
            val=$raw
            ;;
        esac
        case "$key" in
          TAG_UID) LAST_UID=$val ;;
          TYPE) LAST_TYPE=$val ;;
          PAYLOAD) LAST_PAYLOAD=$val ;;
          SOURCE) LAST_SOURCE=$val ;;
          TS) LAST_TS=$val ;;
        esac
        ;;
    esac
  done <"$LASTFILE"
  [ -n "$LAST_TYPE" ] || LAST_TYPE=unknown
  [ -n "$LAST_SOURCE" ] || LAST_SOURCE=last-tag
  [ -n "$LAST_TS" ] || LAST_TS=0
}

save_last_tag() {
  uid="$1"
  typ="$2"
  payload="$3"
  source="$4"
  # Strip CR/LF from fields so the file stays one record per line.
  uid=$(printf '%s' "$uid" | tr -d '\r\n')
  typ=$(printf '%s' "$typ" | tr -d '\r\n')
  payload=$(printf '%s' "$payload" | tr -d '\r\n')
  source=$(printf '%s' "$source" | tr -d '\r\n')
  ts=$(date +%s)
  {
    printf 'TAG_UID=%s\n' "$(nfc_sh_quote "$uid")"
    printf 'TYPE=%s\n' "$(nfc_sh_quote "$typ")"
    printf 'PAYLOAD=%s\n' "$(nfc_sh_quote "$payload")"
    printf 'SOURCE=%s\n' "$(nfc_sh_quote "$source")"
    printf 'TS=%s\n' "$ts"
  } >"$LASTFILE"
}

# --- host sources -----------------------------------------------------------

host_nfc_sysfs_present() {
  [ -e /sys/class/nfc/nfc0 ] || [ -e /sys/class/nfc/nfc1 ]
}

read_fixture_file() {
  f="$1"
  [ -f "$f" ] || return 0
  line=$(head -1 "$f" | tr -d '\r')
  [ -n "$line" ] || return 0
  parse_tag_line "$line" || true
}

# neard D-Bus: best-effort. Returns uid|type|payload|neard or empty.
read_neard() {
  python3 - <<'PY' 2>/dev/null || true
import sys
try:
    import dbus
except ImportError:
    sys.exit(0)
try:
    bus = dbus.SystemBus()
    manager = bus.get_object("org.neard", "/")
    # Manager.GetProperties or ObjectManager
    try:
        om = dbus.Interface(manager, "org.freedesktop.DBus.ObjectManager")
        objs = om.GetManagedObjects()
    except Exception:
        sys.exit(0)
    for path, ifaces in objs.items():
        if "org.neard.Tag" not in ifaces:
            continue
        props = ifaces["org.neard.Tag"]
        uid = str(props.get("Uid", props.get("Type", "neardtag")))
        # Prefer records
        rec_type = "unknown"
        payload = ""
        for p2, if2 in objs.items():
            if "org.neard.Record" not in if2:
                continue
            if not str(p2).startswith(str(path)):
                continue
            r = if2["org.neard.Record"]
            rtype = str(r.get("Type", "")).lower()
            if "uri" in rtype or "smartposter" in rtype:
                rec_type = "uri"
                payload = str(r.get("URI", r.get("Representation", "")))
            elif "text" in rtype:
                rec_type = "text"
                payload = str(r.get("Representation", r.get("Text", "")))
            else:
                payload = str(r.get("Representation", payload))
            break
        if not payload:
            payload = str(props.get("Type", "tag"))
            rec_type = "raw"
        # sanitize
        uid = "".join(c for c in uid if c.isalnum() or c in "-_")[:32] or "neardtag"
        payload = payload.replace("|", " ").replace("\n", " ")
        print(f"{uid}|{rec_type}|{payload}|neard")
        sys.exit(0)
except Exception:
    sys.exit(0)
PY
}

# libnfc-tools nfc-list: parse UID if a tag is present.
read_nfc_list() {
  command -v nfc-list >/dev/null 2>&1 || return 0
  # Quiet; some builds need NFC_DEFAULT_DEVICE
  out=$(nfc-list 2>/dev/null || true)
  [ -n "$out" ] || return 0
  # Match common libnfc lines: "UID (NFCID1): 04  ab  cd …" or "UID: …"
  uid=$(printf '%s\n' "$out" | sed -n 's/.*[Uu][Ii][Dd][^:]*:[[:space:]]*//p' | head -1 | tr -d ' :\r\t' | tr 'a-f' 'A-F')
  [ -n "$uid" ] || return 0
  # Reject "No NFC device" style false positives
  case "$uid" in
    *[Nn][Oo]*|*device*|*error*) return 0 ;;
  esac
  valid_uid "$uid" || return 0
  echo "${uid}|raw|present|nfc-list"
}

# Best-effort: ensure neard is running if installed (does not apk-install).
ensure_neard_running() {
  command -v neard >/dev/null 2>&1 || return 1
  if ! busctl list 2>/dev/null | grep -q org.neard; then
    if command -v systemctl >/dev/null 2>&1; then
      sudo -n systemctl start neard 2>/dev/null || systemctl --user start neard 2>/dev/null || true
    fi
    if command -v rc-service >/dev/null 2>&1; then
      sudo -n rc-service neard start 2>/dev/null || true
    fi
  fi
  busctl list 2>/dev/null | grep -q org.neard || return 1
  # Power adapter + start initiator poll (ski cards / MIFARE need this).
  for adp in /org/neard/nfc0 /org/neard/nfc1; do
    busctl get-property org.neard "$adp" org.neard.Adapter Powered >/dev/null 2>&1 || continue
    busctl set-property org.neard "$adp" org.neard.Adapter Powered b true 2>/dev/null || true
    busctl call org.neard "$adp" org.neard.Adapter StartPollLoop s Initiator 2>/dev/null \
      || busctl call org.neard "$adp" org.neard.Adapter StartPollLoop s Dual 2>/dev/null \
      || true
  done
  return 0
}

host_nfc_userspace_summary() {
  bits=""
  if command -v neard >/dev/null 2>&1 || busctl list 2>/dev/null | grep -q org.neard; then
    bits="${bits}neard "
  fi
  if command -v nfc-list >/dev/null 2>&1; then
    bits="${bits}libnfc-tools "
  fi
  if [ -z "$bits" ]; then
    echo "none (fixture/push/last-tag only; apk add neard and/or libnfc-tools for live field)"
  else
    echo "$bits"
  fi
}

read_host_tag() {
  # Priority: one-shot push > fixture > neard > nfc-list
  # HOST_STACK=none skips live readers (tests / battery).
  line=""
  if [ -f "$PUSHFILE" ]; then
    line=$(read_fixture_file "$PUSHFILE" || true)
    if [ -n "$line" ]; then
      rm -f "$PUSHFILE" 2>/dev/null || true
      echo "$line"
      return 0
    fi
  fi
  line=$(read_fixture_file "$FIXTURE" || true)
  if [ -n "$line" ]; then
    echo "$line"
    return 0
  fi
  case "$HOST_STACK" in
    none) return 0 ;;
  esac
  # neard path
  case "$HOST_STACK" in
    auto|neard)
      ensure_neard_running 2>/dev/null || true
      line=$(read_neard || true)
      if [ -n "$line" ]; then
        echo "$line"
        return 0
      fi
      ;;
  esac
  # libnfc path
  case "$HOST_STACK" in
    auto|libnfc)
      line=$(read_nfc_list || true)
      if [ -n "$line" ]; then
        echo "$line"
        return 0
      fi
      ;;
  esac
  return 0
}

resolve_tag() {
  TAG_LIVE=0
  TAG_UID=""
  TAG_TYPE=""
  TAG_PAYLOAD=""
  TAG_SOURCE=""

  line=$(read_host_tag || true)
  load_last_tag
  now=$(date +%s)
  picked=$(pick_tag_from_line "${line:-}" "$LAST_UID" "$LAST_TYPE" "$LAST_PAYLOAD" "$LAST_SOURCE" "$LAST_TS" "$now" "$MAX_AGE") || return 1

  OLDIFS=$IFS
  IFS='|'
  # shellcheck disable=SC2086
  set -- $picked
  IFS=$OLDIFS
  kind=$1
  TAG_UID=$2
  TAG_TYPE=$3
  TAG_PAYLOAD=$4
  TAG_SOURCE=$5
  case "$kind" in
    LIVE)
      TAG_LIVE=1
      save_last_tag "$TAG_UID" "$TAG_TYPE" "$TAG_PAYLOAD" "$TAG_SOURCE"
      ;;
    LAST|LAST-STALE)
      TAG_LIVE=0
      ;;
  esac
  return 0
}

# --- guest delivery ---------------------------------------------------------

deliver_to_guest() {
  uid="$1"
  typ="$2"
  payload="$3"
  source="$4"

  # Waydroid data dir is root-owned — always write via sudo tee (GPS lesson).
  sudo -n mkdir -p "$GDATA" 2>/dev/null || true
  ts=$(date +%s)
  cat <<EOF | sudo -n tee "$GDATA/nfc-forward-last.txt" >/dev/null
uid=$uid
type=$typ
payload=$payload
source=$source
ts=$ts
EOF
  # Delivery script — no host-side --flags through waydroid shell
  cat <<'EOS' | sudo -n tee "$GDATA/nfc-forward-deliver.sh" >/dev/null
#!/system/bin/sh
# Read last tag file and deliver discovery.
F=/data/local/tmp/nfc-forward-last.txt
if [ ! -f "$F" ]; then
  echo NFC_FWD_DELIVER missing_file
  exit 1
fi
uid=$(sed -n 's/^uid=//p' "$F" | head -1)
typ=$(sed -n 's/^type=//p' "$F" | head -1)
payload=$(sed -n 's/^payload=//p' "$F" | head -1)
source=$(sed -n 's/^source=//p' "$F" | head -1)
ts=$(sed -n 's/^ts=//p' "$F" | head -1)
[ -n "$uid" ] || { echo NFC_FWD_DELIVER bad_uid; exit 1; }

# Always: broadcast for apps + log observability
am broadcast -a com.waydroid.nfc.FORWARD \
  --es uid "$uid" \
  --es type "$typ" \
  --es payload "$payload" \
  --es source "$source" \
  --es ts "$ts" >/dev/null 2>&1
bc_rc=$?

# URI: try VIEW (works without NFC service) and NDEF_DISCOVERED
view_rc=1
ndef_rc=1
if [ "$typ" = "uri" ] && [ -n "$payload" ]; then
  am start -a android.intent.action.VIEW -d "$payload" >/dev/null 2>&1
  view_rc=$?
  am start -a android.nfc.action.NDEF_DISCOVERED -d "$payload" >/dev/null 2>&1
  ndef_rc=$?
fi

# Success = file present + broadcast rc 0 (NFC service may be absent)
if [ -f "$F" ] && [ "$bc_rc" = "0" ]; then
  echo "NFC_FWD_DELIVER_OK uid=$uid type=$typ bc=$bc_rc view=$view_rc ndef=$ndef_rc"
  exit 0
fi
echo "NFC_FWD_DELIVER_FAIL uid=$uid bc=$bc_rc"
exit 1
EOS
  sudo -n chmod 755 "$GDATA/nfc-forward-deliver.sh" 2>/dev/null || true
  out=$(ws /system/bin/sh /data/local/tmp/nfc-forward-deliver.sh 2>&1) || true
  echo "$out" | grep -q 'NFC_FWD_DELIVER_OK' || return 1
  return 0
}

fail_streak_get() {
  cat "$FAILFILE" 2>/dev/null || echo 0
}

fail_streak_set() {
  echo "$1" >"$FAILFILE"
}

# --- lifecycle --------------------------------------------------------------

self_path() {
  case "$0" in
    /*) echo "$0" ;;
    *) echo "$(CDPATH= cd -- "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
  esac
}

write_runner() {
  self=$(self_path)
  runner="$RUNTIME/run-loop.sh"
  cat >"$runner" <<EOF
#!/bin/sh
# Generated by waydroid-nfc-forward — do not edit.
echo \$\$ >"$PIDFILE"
export PATH="$PATH"
export HOME="$HOME"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}"
while true; do
  "$self" once || true
  sleep $INTERVAL
done
EOF
  chmod +x "$runner"
  echo "$runner"
}

install_user_unit() {
  udir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$udir"
  runner=$(write_runner)
  cat >"$udir/$UNIT_NAME" <<EOF
[Unit]
Description=Waydroid host NFC forward (neard/libnfc/fixture → guest)
After=default.target

[Service]
Type=simple
ExecStart=$runner
Restart=always
RestartSec=3
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
  : >>"$LOGFILE"
  rm -f "$FAILFILE"

  install_user_unit
  runner=$(write_runner)

  if systemctl --user is-active "$UNIT_NAME" >/dev/null 2>&1; then
    systemctl --user restart "$UNIT_NAME" 2>/dev/null || true
  else
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

  once || true
  load_last_tag
  notify "Waydroid NFC forward ON" "Auto host→guest tags"
  echo "Started waydroid-nfc-forward (pid=$(cat "$PIDFILE" 2>/dev/null || echo '?')) interval=${INTERVAL}s"
  echo "Last tag: uid=${LAST_UID:-none} type=${LAST_TYPE:-} src=${LAST_SOURCE:-}"
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
  notify "Waydroid NFC forward OFF" "Stopped host→guest NFC"
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

  if host_nfc_sysfs_present; then
    echo "host_nfc: sysfs nfc0 present (nxp-nci class device)"
  else
    echo "host_nfc: no /sys/class/nfc device"
  fi
  echo "host_nfc_userspace: $(host_nfc_userspace_summary)"
  echo "host_stack_mode: $HOST_STACK"

  load_last_tag
  now=$(date +%s)
  if [ -n "$LAST_UID" ]; then
    age=$((now - LAST_TS))
    echo "last_tag: uid=$LAST_UID type=$LAST_TYPE payload=$LAST_PAYLOAD src=$LAST_SOURCE age_s=$age"
  else
    echo "last_tag: (none)"
  fi

  if waydroid_session_running; then
    if guest_boot_ready; then
      echo "waydroid: Session RUNNING boot_completed=1"
    else
      echo "waydroid: Session RUNNING boot_completed=0 (deliver paused)"
    fi
    # Guest observation file + NFC service presence
    echo "guest_nfc_service: $(ws_soft service check nfc | tr -d '\r' | head -1)"
    echo "guest_last_delivery:"
    ws_soft cat /data/local/tmp/nfc-forward-last.txt | head -10 || echo "  (no delivery file yet)"
  else
    echo "waydroid: Session not RUNNING"
  fi
  if [ -f "$LOGFILE" ]; then
    echo "log_tail:"
    tail -5 "$LOGFILE" 2>/dev/null || true
  fi
}

once() {
  if ! resolve_tag; then
    log_rate notag "$LOG_IDLE_S" "once: no tag (host and last-tag empty)"
    return 0
  fi

  # Persist already done for LIVE inside resolve_tag
  if ! waydroid_session_running; then
    log_rate sess_down "$LOG_IDLE_S" "once: session not RUNNING — kept last_tag live=$TAG_LIVE src=$TAG_SOURCE uid=$TAG_UID"
    return 0
  fi

  if ! guest_boot_ready; then
    log_rate boot_wait "$LOG_IDLE_S" "once: guest not boot_completed — skip deliver live=$TAG_LIVE src=$TAG_SOURCE uid=$TAG_UID"
    return 0
  fi

  h=$(tag_hash "$TAG_UID" "$TAG_TYPE" "$TAG_PAYLOAD")
  prev=$(cat "$DELIVERED" 2>/dev/null || true)
  # Always deliver on once when forced via push (LIVE from push) or hash change;
  # also redeliver last-tag once per enable via empty DELIVERED.
  if [ "$h" = "$prev" ] && [ "${NFC_FWD_FORCE:-0}" != "1" ]; then
    log_rate same_tag "$LOG_IDLE_S" "once: skip redeliver same tag uid=$TAG_UID"
    return 0
  fi

  if deliver_to_guest "$TAG_UID" "$TAG_TYPE" "$TAG_PAYLOAD" "$TAG_SOURCE"; then
    echo "$h" >"$DELIVERED"
    fail_streak_set 0
    log "deliver ok live=$TAG_LIVE src=$TAG_SOURCE uid=$TAG_UID type=$TAG_TYPE"
    return 0
  fi

  streak=$(fail_streak_get)
  streak=$((streak + 1))
  fail_streak_set "$streak"
  log "deliver failed streak=$streak live=$TAG_LIVE src=$TAG_SOURCE uid=$TAG_UID"
  return 0
}

# Optional: install host NFC userspace packages (pmOS/Alpine). Needs root network.
install_host_stack() {
  echo "Installing optional host NFC stack (neard + libnfc-tools)…"
  APK=""
  for c in apk /usr/sbin/apk /sbin/apk; do
    if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then
      APK=$c
      break
    fi
  done
  if [ -z "$APK" ]; then
    echo "apk not found — install neard/libnfc-tools manually for your distro." >&2
    return 1
  fi
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo -n "$APK" add --no-cache neard libnfc-tools 2>&1 || sudo -n "$APK" add neard libnfc-tools 2>&1
  else
    echo "Need passwordless sudo or run as root: $APK add neard libnfc-tools" >&2
    return 1
  fi
  ensure_neard_running || true
  echo "host_nfc_userspace: $(host_nfc_userspace_summary)"
}

# Push a synthetic/live tag through the shipped once path (for tests & CLI).
push_tag() {
  typ="${1:-}"
  payload="${2:-}"
  uid="${3:-}"
  if [ -z "$typ" ] || [ -z "$payload" ]; then
    echo "Usage: waydroid-nfc-forward push <uri|text|raw> <payload> [uid]" >&2
    return 1
  fi
  valid_type "$typ" || {
    # allow auto-classify if user passed payload as first arg style
    echo "Invalid type: $typ (uri|text|raw|unknown)" >&2
    return 1
  }
  if [ -z "$uid" ]; then
    uid=$(printf '%s' "$payload" | cksum | awk '{printf "T%08X", $1}')
  fi
  line=$(parse_tag_line "${uid}|${typ}|${payload}|push") || {
    echo "Invalid tag fields" >&2
    return 1
  }
  mkdir -p "$STATE_ROOT"
  echo "$line" >"$PUSHFILE"
  # Force redeliver even if same hash
  rm -f "$DELIVERED"
  NFC_FWD_FORCE=1 once
  echo "Pushed: $line"
}

selftest() {
  fail=0
  echo "selftest: valid_uid"
  if ! valid_uid "04A1B2C3"; then echo "FAIL hex uid"; fail=1; fi
  if ! valid_uid "DEADBEEF"; then echo "FAIL deadbeef"; fail=1; fi
  if valid_uid ""; then echo "FAIL empty uid"; fail=1; fi
  if valid_uid "x"; then echo "FAIL short"; fail=1; fi

  echo "selftest: parse_tag_line"
  out=$(parse_tag_line "AABBCCDD|uri|https://example.com/t|fixture") || { echo "FAIL parse"; fail=1; out=""; }
  case "$out" in
    AABBCCDD\|uri\|https://example.com/t\|fixture) echo "ok parse: $out" ;;
    *) echo "FAIL parse got: $out"; fail=1 ;;
  esac
  if parse_tag_line "bad|uri||fixture" 2>/dev/null; then echo "FAIL empty uri payload"; fail=1; fi

  echo "selftest: classify_payload"
  c=$(classify_payload "https://x.test/y")
  [ "$c" = "uri" ] || { echo "FAIL classify uri got $c"; fail=1; }
  c=$(classify_payload "hello world")
  [ "$c" = "text" ] || { echo "FAIL classify text got $c"; fail=1; }
  echo "ok classify"

  echo "selftest: pick_tag live"
  out=$(pick_tag_from_line "11223344|text|hello|neard" "" "" "" "" 0 100 86400) || { echo "FAIL pick live"; fail=1; out=""; }
  case "$out" in
    LIVE\|11223344\|text\|hello\|neard) echo "ok pick live: $out" ;;
    *) echo "FAIL pick live got: $out"; fail=1 ;;
  esac

  echo "selftest: pick_tag last when empty line"
  out=$(pick_tag_from_line "" "99AA" "uri" "https://last.test" "last-tag" 50 100 86400) || { echo "FAIL pick last"; fail=1; out=""; }
  case "$out" in
    LAST\|99AA\|uri\|https://last.test\|*) echo "ok pick last: $out" ;;
    *) echo "FAIL pick last got: $out"; fail=1 ;;
  esac

  echo "selftest: pick_tag rejects empty"
  if pick_tag_from_line "" "" "" "" "" 0 100 86400 2>/dev/null; then
    echo "FAIL should reject empty"; fail=1
  else
    echo "ok reject empty"
  fi

  echo "selftest: save/load last-tag"
  old_state=${STATE_ROOT}
  STATE_ROOT="${NFC_FWD_TEST_STATE:-$STATE_ROOT/selftest-$$}"
  LASTFILE="$STATE_ROOT/last-tag.env"
  mkdir -p "$STATE_ROOT"
  save_last_tag "CAFEBABE" "uri" "https://persist.test" "selftest"
  load_last_tag
  if [ "$LAST_UID" = "CAFEBABE" ] && [ "$LAST_TYPE" = "uri" ] && [ "$LAST_PAYLOAD" = "https://persist.test" ]; then
    echo "ok save/load"
  else
    echo "FAIL save/load uid=$LAST_UID type=$LAST_TYPE payload=$LAST_PAYLOAD"
    fail=1
  fi

  echo "selftest: save/load text payload with spaces"
  spaced="hello world; not a command"
  save_last_tag "D00D" "text" "$spaced" "selftest-space"
  # Prove file is quoted (no bare PAYLOAD=hello world)
  if grep -q "^PAYLOAD='hello world; not a command'$" "$LASTFILE" \
    || grep -Fq "PAYLOAD='hello world; not a command'" "$LASTFILE"; then
    :
  else
    echo "FAIL expected quoted PAYLOAD in file:"; cat "$LASTFILE"; fail=1
  fi
  load_last_tag
  if [ "$LAST_UID" = "D00D" ] && [ "$LAST_TYPE" = "text" ] && [ "$LAST_PAYLOAD" = "$spaced" ] && [ "$LAST_SOURCE" = "selftest-space" ]; then
    echo "ok save/load spaced text: [$LAST_PAYLOAD]"
  else
    echo "FAIL spaced save/load uid=$LAST_UID type=$LAST_TYPE payload=[$LAST_PAYLOAD] src=$LAST_SOURCE"
    fail=1
  fi
  # Apostrophe in payload
  save_last_tag "AE" "text" "it's fine" "selftest-apos"
  load_last_tag
  if [ "$LAST_PAYLOAD" = "it's fine" ]; then
    echo "ok save/load apostrophe"
  else
    echo "FAIL apostrophe payload=[$LAST_PAYLOAD]"; fail=1
  fi
  rm -rf "$STATE_ROOT"
  STATE_ROOT=$old_state
  LASTFILE="$STATE_ROOT/last-tag.env"

  echo "selftest: ndef helpers"
  th=$(ndef_text_payload_hex "Hi")
  echo "$th" | grep -Eq '^[0-9a-f]+$' || { echo "FAIL ndef text hex"; fail=1; }
  uh=$(ndef_uri_payload_hex "https://e.test")
  echo "$uh" | grep -Eq '^[0-9a-f]+$' || { echo "FAIL ndef uri hex"; fail=1; }
  echo "ok ndef helpers"

  echo "selftest: tag_hash stable"
  h1=$(tag_hash "A" "text" "p")
  h2=$(tag_hash "A" "text" "p")
  h3=$(tag_hash "A" "text" "q")
  [ "$h1" = "$h2" ] || { echo "FAIL hash unstable"; fail=1; }
  [ "$h1" != "$h3" ] || { echo "FAIL hash collision"; fail=1; }
  echo "ok tag_hash"

  if [ "$fail" -ne 0 ]; then
    echo "SELFTEST_FAILED"
    return 1
  fi
  echo "ALL_NFC_FWD_SELFTESTS_OK"
  return 0
}

once_loop() {
  while true; do
    once || true
    sleep "$INTERVAL"
  done
}

cmd="${1:-status}"
shift $(( $# > 0 ? 1 : 0 )) || true

case "$cmd" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  toggle)
    if is_running; then stop; else start; fi
    ;;
  once) once ;;
  once-loop) once_loop ;;
  enable) enable_autostart ;;
  disable) disable_autostart ;;
  push) push_tag "$@" ;;
  install-host-stack) install_host_stack ;;
  selftest) selftest ;;
  *)
    echo "Usage: waydroid-nfc-forward start|stop|status|toggle|once|enable|disable|selftest|push|install-host-stack|once-loop" >&2
    exit 2
    ;;
esac
