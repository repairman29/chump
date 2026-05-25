#!/usr/bin/env bash
# scripts/ci/test-fleet-autopilot.sh — META-090
#
# Smoke test for the chump fleet autopilot orchestrator. Validates the source
# contract + status command + bypass env, without actually installing any
# launchd plists (skip cleanly on Linux CI).
#
# capability-guard-exempt: source-contract assertions only; no chump binary invocation

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/coord/fleet-autopilot.sh"
INSTALLER="$REPO_ROOT/scripts/setup/install-fleet-autopilot-launchd.sh"

echo "=== META-090 fleet autopilot tests ==="

# (1) Source contract — orchestrator
[[ -f "$TARGET" ]] && ok "autopilot script exists" || { fail "missing $TARGET"; exit 1; }
[[ -x "$TARGET" ]] && ok "autopilot script executable" || fail "$TARGET not executable"

for needle in \
    "AUTOPILOT_LAYERS=" \
    "dev.chump.pr-auto-rebase" \
    "dev.chump.auto-arm-sweeper" \
    "com.chump.pr-pulse-consumer" \
    "com.chump.transient-retrigger" \
    "com.chump.oracle-refresh" \
    "com.chump.curator-jit-scheduler" \
    "com.chump.opus-curator" \
    "com.chump.emergency-fast-path" \
    "com.chump.fleet-autopilot" \
    "com.chump.refresh-runner-binary" \
    "cmd_start" \
    "cmd_stop" \
    "cmd_status" \
    "cmd_heartbeat" \
    "autopilot_started" \
    "autopilot_stopped" \
    "autopilot_heartbeat" \
    "autopilot_partial" \
    "CHUMP_AUTOPILOT_DISABLED" \
    "chump-fleet-bootstrap.sh"; do
    if grep -qF "$needle" "$TARGET"; then
        ok "contract: $needle"
    else
        fail "contract missing: $needle"
    fi
done

# (2) AC#1 requirement: >=10 daemons configured (post-RESILIENT-021: dev.* + com.* mix)
layer_count=$(grep -cE '^\s+"(com|dev)\.chump\.' "$TARGET")
if [[ "$layer_count" -ge 10 ]]; then
    ok "AC#1: $layer_count daemon layers configured (>=10 required)"
else
    fail "AC#1: only $layer_count layers configured (need >=10 per AC#7 smoke target)"
fi

# (3) Installer contract
[[ -f "$INSTALLER" ]] && ok "launchd installer exists" || fail "missing $INSTALLER"

for needle in \
    "PLIST_NAME=\"com.chump.fleet-autopilot\"" \
    "StartInterval" \
    "300" \
    "RunAtLoad" \
    "heartbeat" \
    "uninstall"; do
    if grep -qF -- "$needle" "$INSTALLER"; then
        ok "installer contract: $needle"
    else
        fail "installer missing: $needle"
    fi
done

# (4) Help text reachable
if "$TARGET" --help 2>&1 | grep -qE "start|stop|status"; then
    ok "help text mentions start/stop/status"
else
    fail "help text missing standard commands"
fi

# (5) status command runs without crashing (no daemons loaded ≠ failure)
if "$TARGET" status >/dev/null 2>&1; then
    ok "status command exits 0 on clean state"
else
    fail "status command exits non-zero unexpectedly"
fi

# (6) status --json produces parseable JSON
if "$TARGET" status json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'layers' in d and 'loaded' in d" 2>/dev/null; then
    ok "status json output parseable + has layers/loaded keys"
else
    fail "status json output not parseable"
fi

# (7) bypass env honored
if CHUMP_AUTOPILOT_DISABLED=1 "$TARGET" start 2>&1 | grep -qE "BYPASS|CHUMP_AUTOPILOT_DISABLED"; then
    ok "CHUMP_AUTOPILOT_DISABLED bypass honored"
else
    fail "bypass env not honored on start"
fi

# (8) Unknown command rejected
if ! "$TARGET" nonsense-command 2>/dev/null; then
    ok "unknown command rejected with non-zero exit"
else
    fail "unknown command silently accepted"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
echo "OK"
exit 0
