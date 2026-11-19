#!/bin/sh
# Simulation tests for tesla-frunk-root.sh. Everything is stubbed (busctl, lxc-*, systemctl,
# logger); nothing talks to BlueZ, Waydroid or a car. Run: sh run-sim-tests.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../tesla-frunk-root.sh"
PATH="$HERE/bin:$PATH"; export PATH
pass=0; fail=0; BR=
setup() {
  SIM=$(mktemp -d); export SIM
  export FRUNK_FEATURES_FILE="$SIM/features" FRUNK_LOCK="$SIM/lock" FRUNK_WAIT_S=${1:-3}
  : > "$SIM/sends"; touch "$SIM/lxc_running"; cp "$HERE/fixtures/dumpsys-connected.txt" "$SIM/dumpsys"
}
bridge() { # $1 delay|never, $2 features yes|no
  sh "$HERE/fake-bridge.sh" "$1" & BR=$!; echo "$BR" > "$SIM/bridge_pid"
  [ "$2" = yes ] && echo "kick-usr1 early-drop-reconnect pid=$BR" > "$SIM/features"
  sleep 0.3
}
teardown() { [ -n "$BR" ] && kill "$BR" 2>/dev/null; BR=; rm -rf "$SIM"; }
check() { # name expected_rc actual_rc expected_sends extra_cond
  sends=$(wc -l < "$SIM/sends"); sends=$((sends + 0))
  if [ "$2" = "$3" ] && [ "$4" = "$sends" ] && eval "$5"; then pass=$((pass+1)); echo "PASS $1 (rc=$3 sends=$sends) :: $(tail -n1 "$SIM/log" 2>/dev/null)"
  else fail=$((fail+1)); echo "FAIL $1 (rc=$3 want $2, sends=$sends want $4) :: $(cat "$SIM/log" 2>/dev/null)"; fi
}

setup; touch "$SIM/link_up"; sh "$SCRIPT" >/dev/null; rc=$?
check "A link up + Connected -> sent" 0 $rc 1 'grep -q "result=sent .*link_at_press=up kick=none" "$SIM/log"'; teardown

setup; bridge 2 yes; sh "$SCRIPT" >/dev/null; rc=$?
check "B link down, kick, car up after 2 s -> sent" 0 $rc 1 'grep -q kicked "$SIM/kicks" && grep -q "result=sent .*link_at_press=down kick=sent link=up" "$SIM/log"'; teardown

setup 2; bridge never yes; t0=$(date +%s); sh "$SCRIPT" >/dev/null; rc=$?; dt=$(( $(date +%s) - t0 ))
check "C link never up -> refused after wait" 3 $rc 0 '[ $dt -ge 2 ] && [ $dt -le 4 ] && grep -q "result=refused reason=no-car-link .*kick=sent" "$SIM/log"'; teardown

setup 1; bridge 0 no; sh "$SCRIPT" >/dev/null; rc=$?
check "D old bridge (no features) -> no USR1, bridge alive" 3 $rc 0 '[ ! -e "$SIM/kicks" ] && kill -0 $BR && grep -q "kick=unsupported" "$SIM/log"'; teardown

setup 1; echo "kick-usr1 early-drop-reconnect pid=999999" > "$SIM/features"; bridge 0 no; sh "$SCRIPT" >/dev/null; rc=$?
check "E stale features pid -> no USR1" 3 $rc 0 '[ ! -e "$SIM/kicks" ] && grep -q "kick=unsupported" "$SIM/log"'; teardown

setup; rm "$SIM/lxc_running"; sh "$SCRIPT" >/dev/null; rc=$?
check "F Waydroid down -> 4" 4 $rc 0 'grep -q "reason=waydroid-not-running" "$SIM/log"'; teardown

setup 1; touch "$SIM/link_up"; cp "$HERE/fixtures/dumpsys-notconnected.txt" "$SIM/dumpsys"; sh "$SCRIPT" >/dev/null; rc=$?
check "G link up but app not Connected -> 3" 3 $rc 0 'grep -q "reason=phone-key-not-connected" "$SIM/log"'; teardown

setup 1; touch "$SIM/link_up"; cp "$HERE/fixtures/dumpsys-nobutton.txt" "$SIM/dumpsys"; sh "$SCRIPT" >/dev/null; rc=$?
check "H Connected but no Front Trunk action -> 3" 3 $rc 0 'grep -q "reason=no-front-trunk-action" "$SIM/log"'; teardown

setup; touch "$SIM/link_up"; export SIM_SEND_DELAY=1
sh "$SCRIPT" >/dev/null & p1=$!; sleep 0.3; sh "$SCRIPT" >/dev/null; rc2=$?; wait $p1; rc1=$?; unset SIM_SEND_DELAY
check "I two presses at once -> one send, second busy" 6 $rc2 1 '[ $rc1 = 0 ] && grep -q "result=busy" "$SIM/log"'; teardown

setup; out=$(sh "$SCRIPT" --check-only "$HERE/fixtures/dumpsys-connected.txt"); rc=$?
check "J --check-only fixture parse" 0 $rc 0 '[ "$out" = ok ] && [ "$(sh "$SCRIPT" --check-only "$HERE/fixtures/dumpsys-nobutton.txt")" = nobutton ]'; teardown

echo "sim: $pass passed, $fail failed"; [ $fail = 0 ]
