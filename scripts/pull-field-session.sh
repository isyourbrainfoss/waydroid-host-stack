#!/bin/sh
# Pull field logs from fajita (or process a local tree) + Tesla-oriented summary.
#
# Usage:
#   pull-field-session.sh                 # latest bt-log-session + gps/nfc/soft-hci
#   pull-field-session.sh session-NAME
#   pull-field-session.sh --list
#   pull-field-session.sh --local DIR     # offline: summarize existing capture tree
#   pull-field-session.sh --full-logcat   # include huge guest-logcat*.log (default: skip)
#   pull-field-session.sh --skip-logcat   # default; omit guest-logcat*.follow.log
#
# Env:
#   FAJITA_HOST   ssh host (default fajita)
#   OUT_DIR       local output root (default ./field-captures)
set -eu

HOST="${FAJITA_HOST:-fajita}"
OUT_ROOT="${OUT_DIR:-./field-captures}"
SSH_OPTS="${PULL_SSH_OPTS:--o ConnectTimeout=10 -o BatchMode=yes}"
SKIP_LOGCAT=1
SESSION_ARG=""
LOCAL_DIR=""
MODE=pull

while [ $# -gt 0 ]; do
  case "$1" in
    --list) MODE=list; shift ;;
    --local)
      MODE=local
      LOCAL_DIR="${2:-}"
      shift 2 || shift
      ;;
    --full-logcat) SKIP_LOGCAT=0; shift ;;
    --skip-logcat) SKIP_LOGCAT=1; shift ;;
    -h|--help)
      echo "Usage: $0 [session-NAME] [--list|--local DIR] [--skip-logcat|--full-logcat]"
      exit 0
      ;;
    --*)
      echo "Unknown flag: $1" >&2
      exit 2
      ;;
    *)
      SESSION_ARG="$1"
      shift
      ;;
  esac
done

# --- summary helpers (work offline on a capture dir) -------------------------

write_sizes() {
  root="$1"
  outf="$2"
  {
    echo "# Sizes"
    echo
    echo '```'
    du -sh "$root"/* "$root"/*/* 2>/dev/null | head -80 || du -ah "$root" 2>/dev/null | head -80
    echo '```'
  } >"$outf"
}

write_tesla_timeline() {
  root="$1"
  # Compact Phone Key path: first NOT found → Found in whitelist → unlocked
  {
    echo "## Tesla Phone Key timeline (compact)"
    echo
    echo '```'
    if command -v rg >/dev/null 2>&1; then
      rg -n --no-messages \
        -e 'Did NOT find key' \
        -e 'Found \[.*\] in whitelist' \
        -e 'already in whitelist' \
        -e 'Got vehicle status:.*unlocked' \
        -e 'Got vehicle status:.*locked' \
        --glob '!SUMMARY.md' --glob '!SIZES.md' --glob '!README.md' --glob '!MANIFEST.txt' \
        "$root" 2>/dev/null | head -80 || echo "(no timeline hits)"
    else
      grep -RniE 'Did NOT find key|Found \[.*\] in whitelist|already in whitelist|Got vehicle status:.*(unlocked|locked)' \
        --exclude='SUMMARY.md' --exclude='SIZES.md' --exclude='README.md' --exclude='MANIFEST.txt' \
        "$root" 2>/dev/null | head -80 \
        || echo "(no timeline hits)"
    fi
    echo '```'
    echo
  }
}

write_tesla_summary() {
  root="$1"
  outf="$2"
  {
    echo "# Field pull summary"
    echo
    echo "Generated: $(date -Is 2>/dev/null || date)"
    echo "Tree: \`$root\`"
    echo
    write_tesla_timeline "$root"
    echo "## Tesla / Soft HCI greps (samples)"
    echo
    hits=0
    for pat in 'Found \[.*\] in whitelist' 'Did NOT find key' BLEVehicleController 'vehicle status:.*unlocked' VCSEC 'inject ok' 'deliver ok'; do
      echo "### \`$pat\`"
      echo
      if command -v rg >/dev/null 2>&1; then
        if rg -n --no-messages -i -e "$pat" \
          --glob '!SUMMARY.md' --glob '!SIZES.md' --glob '!MANIFEST.txt' --glob '!README.md' \
          "$root" 2>/dev/null | head -15; then
          hits=$((hits + 1))
        else
          echo "_no matches_"
        fi
      else
        if grep -Rni --exclude='SUMMARY.md' --exclude='SIZES.md' --exclude='MANIFEST.txt' \
          --exclude='README.md' -E -- "$pat" "$root" 2>/dev/null | head -15; then
          hits=$((hits + 1))
        else
          echo "_no matches_"
        fi
      fi
      echo
    done
    echo "## Artifact checklist"
    echo
    for rel in \
      bt-session \
      soft-hci/waydroid-bt-host.journal.txt \
      soft-hci/host-bridge-tail.txt \
      gps/forward.log \
      gps/last-known.env \
      nfc/forward.log \
      nfc/last-tag.env \
      nfc/nfc-forward-last.txt \
      phone-status.txt \
      SIZES.md
    do
      if [ -e "$root/$rel" ] || [ -d "$root/$rel" ]; then
        echo "- [x] \`$rel\`"
      else
        echo "- [ ] \`$rel\` (missing)"
      fi
    done
    echo
    echo "Pattern hit groups (non-zero sections): $hits"
  } >"$outf"
}

summarize_tree() {
  root="$1"
  write_sizes "$root" "$root/SIZES.md"
  write_tesla_summary "$root" "$root/SUMMARY.md"
  echo "Summary: $root/SUMMARY.md"
  echo "Sizes:   $root/SIZES.md"
}

# --- modes ------------------------------------------------------------------

list_remote() {
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$HOST" 'ls -1dt ~/bt-log-sessions/session-* 2>/dev/null | head -20'
}

if [ "$MODE" = "list" ]; then
  list_remote
  exit 0
fi

if [ "$MODE" = "local" ]; then
  if [ -z "$LOCAL_DIR" ] || [ ! -d "$LOCAL_DIR" ]; then
    echo "Usage: $0 --local DIR" >&2
    exit 2
  fi
  summarize_tree "$LOCAL_DIR"
  echo "PULL_LOCAL_OK"
  exit 0
fi

stamp=$(date +%Y%m%d-%H%M%S)
OUT="$OUT_ROOT/pull-$stamp"
mkdir -p "$OUT"

echo "Pulling from $HOST → $OUT (skip_logcat=$SKIP_LOGCAT)"

set +e
# shellcheck disable=SC2086
REMOTE_LATEST=$(ssh $SSH_OPTS "$HOST" '
  if [ -n "'"$SESSION_ARG"'" ]; then
    if [ -d "$HOME/bt-log-sessions/'"$SESSION_ARG"'" ]; then
      echo "$HOME/bt-log-sessions/'"$SESSION_ARG"'"
    elif [ -d "'"$SESSION_ARG"'" ]; then
      echo "'"$SESSION_ARG"'"
    else
      echo ""
    fi
  else
    ls -1dt "$HOME"/bt-log-sessions/session-* 2>/dev/null | head -1
  fi
' 2>"$OUT/ssh.err")
ssh_rc=$?
set -e

if [ "$ssh_rc" -ne 0 ]; then
  echo "SSH failed (rc=$ssh_rc) — see $OUT/ssh.err"
  cat "$OUT/ssh.err" 2>/dev/null || true
  {
    echo "ssh_failed: $(date -Is)"
    echo "host: $HOST"
  } >"$OUT/MANIFEST.txt"
  # Still allow offline proof via empty tree + note
  summarize_tree "$OUT"
  echo "PULL_SSH_FAILED"
  exit 1
fi

# Resolve remote home/runtime on the phone — never expand $HOME on the desk.
# shellcheck disable=SC2086
REMOTE_HOME=$(ssh $SSH_OPTS "$HOST" 'printf %s "$HOME"' 2>>"$OUT/ssh.err" || true)
# shellcheck disable=SC2086
REMOTE_UID=$(ssh $SSH_OPTS "$HOST" 'id -u' 2>>"$OUT/ssh.err" || true)
REMOTE_RUNTIME="/run/user/${REMOTE_UID:-10000}"
if [ -z "$REMOTE_HOME" ]; then
  echo "Could not resolve remote HOME" | tee -a "$OUT/ssh.err"
  REMOTE_HOME="/home/user"
fi
echo "remote_home=$REMOTE_HOME runtime=$REMOTE_RUNTIME" | tee "$OUT/remote-paths.txt"

if [ -n "$REMOTE_LATEST" ]; then
  echo "BT session: $REMOTE_LATEST"
  mkdir -p "$OUT/bt-session"
  if [ "$SKIP_LOGCAT" = "1" ]; then
    # shellcheck disable=SC2086
    rsync -az -e "ssh $SSH_OPTS" \
      --exclude='guest-logcat*.log' --exclude='guest-logcat*.follow.log' \
      --exclude='*.follow.log.gz' \
      "$HOST:$REMOTE_LATEST/" "$OUT/bt-session/" 2>>"$OUT/ssh.err" || \
      scp $SSH_OPTS -r "$HOST:$REMOTE_LATEST/." "$OUT/bt-session/" 2>>"$OUT/ssh.err" || true
    echo "logcat: skipped (pass --full-logcat for full guest logs)" | tee "$OUT/bt-session/LOGCAT_SKIPPED.txt"
  else
    # shellcheck disable=SC2086
    rsync -az -e "ssh $SSH_OPTS" "$HOST:$REMOTE_LATEST/" "$OUT/bt-session/" 2>>"$OUT/ssh.err" || \
      scp $SSH_OPTS -r "$HOST:$REMOTE_LATEST/." "$OUT/bt-session/" 2>>"$OUT/ssh.err" || true
  fi
  # Compress any remaining large files
  if command -v gzip >/dev/null 2>&1; then
    find "$OUT/bt-session" -type f -name '*.log' -size +2M -exec gzip -f {} \; 2>/dev/null || true
  fi
  echo "$REMOTE_LATEST" >"$OUT/bt-session-remote-path.txt"
else
  echo "No bt-log-session found on phone (ok if you only want GPS/NFC)."
fi

mkdir -p "$OUT/gps" "$OUT/nfc" "$OUT/soft-hci"

# shellcheck disable=SC2086
ssh $SSH_OPTS "$HOST" 'export PATH="$HOME/.local/bin:/usr/bin:/bin"
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  echo "=== runtime ==="
  for d in waydroid-gps-forward waydroid-nfc-forward; do
    echo "--- $d ---"
    ls -la "$XDG_RUNTIME_DIR/$d" 2>/dev/null || true
    ls -la "$HOME/.local/state/$d" 2>/dev/null || true
  done
  echo "=== status ==="
  command -v waydroid-gps-forward >/dev/null && waydroid-gps-forward status || true
  command -v waydroid-nfc-forward >/dev/null && waydroid-nfc-forward status || true
  echo "=== waydroid ==="
  waydroid status 2>/dev/null || true
  echo "=== soft hci units ==="
  systemctl is-active waydroid-bt-host 2>/dev/null || true
  systemctl --user is-active waydroid-bt-host 2>/dev/null || true
' >"$OUT/phone-status.txt" 2>&1 || true

# Soft HCI / host bridge journals
# shellcheck disable=SC2086
ssh $SSH_OPTS "$HOST" 'journalctl -u waydroid-bt-host -n 500 --no-pager 2>/dev/null; journalctl --user -u waydroid-bt-host -n 200 --no-pager 2>/dev/null' \
  >"$OUT/soft-hci/waydroid-bt-host.journal.txt" 2>/dev/null || true
# Prefer session copy; also try latest host-bridge under remote bt-log-sessions via ssh+tar (no local $HOME).
if [ -f "$OUT/bt-session/host-bridge-tail.txt" ]; then
  cp -f "$OUT/bt-session/host-bridge-tail.txt" "$OUT/soft-hci/host-bridge-tail.txt" 2>/dev/null || true
else
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$HOST" "ls -1t \"\$HOME\"/bt-log-sessions/session-*/host-bridge-tail.txt 2>/dev/null | head -1" \
    | while read -r rp; do
        [ -n "$rp" ] || continue
        # shellcheck disable=SC2086
        scp $SSH_OPTS "$HOST:$rp" "$OUT/soft-hci/host-bridge-tail.txt" 2>>"$OUT/ssh.err" || true
      done
fi
if [ -f "$OUT/bt-session/waydroid-bt-host.follow.log" ]; then
  cp -f "$OUT/bt-session/waydroid-bt-host.follow.log" "$OUT/soft-hci/" 2>/dev/null || true
fi

# GPS / NFC files — use REMOTE_HOME / REMOTE_RUNTIME resolved above (desk $HOME must not expand).
# shellcheck disable=SC2086
scp $SSH_OPTS "$HOST:$REMOTE_RUNTIME/waydroid-gps-forward/forward.log" "$OUT/gps/" 2>>"$OUT/ssh.err" || true
# shellcheck disable=SC2086
scp $SSH_OPTS "$HOST:$REMOTE_HOME/.local/state/waydroid-gps-forward/last-known.env" "$OUT/gps/" 2>>"$OUT/ssh.err" || true
# shellcheck disable=SC2086
scp $SSH_OPTS "$HOST:$REMOTE_RUNTIME/waydroid-nfc-forward/forward.log" "$OUT/nfc/" 2>>"$OUT/ssh.err" || true
# shellcheck disable=SC2086
scp $SSH_OPTS "$HOST:$REMOTE_HOME/.local/state/waydroid-nfc-forward/last-tag.env" "$OUT/nfc/" 2>>"$OUT/ssh.err" || true
# Guest NFC last delivery (waydroid data path)
# shellcheck disable=SC2086
scp $SSH_OPTS "$HOST:$REMOTE_HOME/.local/share/waydroid/data/local/tmp/nfc-forward-last.txt" "$OUT/nfc/" 2>>"$OUT/ssh.err" || true

# Fail soft if core state files missing when phone-status said they exist
if [ -f "$OUT/phone-status.txt" ] && grep -q 'last-known.env' "$OUT/phone-status.txt" 2>/dev/null; then
  if [ ! -f "$OUT/gps/last-known.env" ]; then
    echo "WARN: last-known.env listed on phone but not pulled" | tee -a "$OUT/ssh.err"
  fi
fi

summarize_tree "$OUT"

{
  echo "pulled: $(date -Is)"
  echo "host: $HOST"
  echo "out: $OUT"
  echo "bt: ${REMOTE_LATEST:-none}"
  du -sh "$OUT"/* 2>/dev/null || true
} | tee "$OUT/MANIFEST.txt"

echo "Done: $OUT"
echo "PULL_OK"
