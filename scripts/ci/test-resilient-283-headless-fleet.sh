#!/usr/bin/env bash
# RESILIENT-283: headless-native fleet worker runner.
#
# Proves fleet_headless_mode() (scripts/dispatch/lib/headless-detect.sh)
# correctly decides whether run-fleet.sh should skip the tmux control.sh
# dashboard (which crashes on a fresh headless Linux node — `clear`
# requires TERM, killing the tmux session before any worker pane spawns)
# and run a worker in pane 0 instead.
#
# Without lib/headless-detect.sh (pre-fix), this file does not exist and
# the test fails at the `source` line below.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LIB="$REPO_ROOT/scripts/dispatch/lib/headless-detect.sh"

fail=0

if [[ ! -f "$LIB" ]]; then
    echo "FAIL: $LIB does not exist"
    exit 1
fi

# shellcheck source=scripts/dispatch/lib/headless-detect.sh
source "$LIB"

check() {
    local desc="$1" requested="$2" term="$3" expected="$4"
    local got
    got="$(fleet_headless_mode "$requested" "$term")"
    if [[ "$got" != "$expected" ]]; then
        echo "FAIL: $desc — fleet_headless_mode('$requested','$term') = '$got', expected '$expected'"
        fail=1
    else
        echo "PASS: $desc"
    fi
}

# Fresh headless Linux node (systemd/ssh, no TTY attached): TERM unset.
check "unset TERM -> headless"      "auto" ""              "1"
# Some minimal shells leave TERM=dumb rather than unset.
check "TERM=dumb -> headless"       "auto" "dumb"           "1"
# Normal interactive terminal: dashboard should still run.
check "TERM=xterm-256color -> interactive" "auto" "xterm-256color" "0"
check "TERM=screen -> interactive"  "auto" "screen"         "0"
# Explicit operator overrides win regardless of TERM.
check "forced headless overrides TERM" "1" "xterm-256color" "1"
check "forced interactive overrides missing TERM" "0" "" "0"

# run-fleet.sh must source the lib and gate the control.sh launch on it —
# guards against a future edit reintroducing an unconditional
# `tmux new-session ... control.sh` that regresses the headless path.
RUN_FLEET="$REPO_ROOT/scripts/dispatch/run-fleet.sh"
if ! grep -q 'source "\$SCRIPT_DIR/lib/headless-detect.sh"' "$RUN_FLEET"; then
    echo "FAIL: run-fleet.sh no longer sources lib/headless-detect.sh"
    fail=1
else
    echo "PASS: run-fleet.sh sources lib/headless-detect.sh"
fi
if ! grep -q 'fleet_headless_mode' "$RUN_FLEET"; then
    echo "FAIL: run-fleet.sh no longer calls fleet_headless_mode"
    fail=1
else
    echo "PASS: run-fleet.sh calls fleet_headless_mode"
fi

exit "$fail"
