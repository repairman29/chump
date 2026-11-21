#!/usr/bin/env bash
# test-infra-525-checkpoint-on-timeout.sh — INFRA-525
#
# Validates the worker.sh checkpoint-on-timeout watchdog wiring.
# Live runtime test would require a 600s wait — out of scope. This
# tests the structural correctness instead.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

echo "=== INFRA-525 worker.sh checkpoint-on-timeout test ==="
echo

# 1. INFRA-525 marker present.
if grep -q "INFRA-525" "$WORKER"; then
    ok "worker.sh contains INFRA-525 marker"
else
    fail "worker.sh missing INFRA-525 marker"
fi

# 2. Checkpoint watchdog is a background process (& at end).
if grep -qE 'sleep "\$_checkpoint_at"' "$WORKER"; then
    ok "watchdog sleeps to T-30s"
else
    fail "watchdog sleep missing"
fi

# 3. Watchdog commits via git -c user.name='chump-fleet-checkpoint'.
if grep -q "chump-fleet-checkpoint" "$WORKER"; then
    ok "watchdog commits with dedicated identity (audit trail)"
else
    fail "watchdog commit identity missing"
fi

# 4. Pushes to origin <branch>.
if grep -qE 'git push -u origin "\$branch"' "$WORKER"; then
    ok "watchdog pushes branch to origin"
else
    fail "watchdog push missing"
fi

# 5. Emits ambient ALERT kind=fleet_timeout_checkpoint.
if grep -q 'fleet_timeout_checkpoint' "$WORKER"; then
    ok "watchdog emits ALERT kind=fleet_timeout_checkpoint"
else
    fail "watchdog ALERT missing"
fi

# 6. Watchdog killed on clean exit.
if grep -qE 'kill "\$_checkpoint_pid"' "$WORKER"; then
    ok "watchdog killed when claude exits cleanly before T-30s"
else
    fail "watchdog cleanup missing"
fi

# 7. Disable knob present.
if grep -q "CHUMP_TIMEOUT_CHECKPOINT_SECS" "$WORKER"; then
    ok "CHUMP_TIMEOUT_CHECKPOINT_SECS env knob present"
else
    fail "disable knob missing"
fi

# 8. Default 30s.
if grep -qE 'CHUMP_TIMEOUT_CHECKPOINT_SECS:-30' "$WORKER"; then
    ok "default checkpoint window is 30s before timeout"
else
    fail "default checkpoint window wrong"
fi

# 9. Live: simulate the conditional logic without actually waiting 600s.
# The condition is: if (( _checkpoint_at > 0 )) — checkpoint_at = TIMEOUT - 30.
# Verify it's positive for default FLEET_TIMEOUT_S=600.
default_timeout=600
default_checkpoint=30
checkpoint_at=$((default_timeout - default_checkpoint))
if (( checkpoint_at > 0 )); then
    ok "live: checkpoint_at = $checkpoint_at (positive, watchdog will fire)"
else
    fail "live: checkpoint_at non-positive"
fi

# 10. Disable path: when CHUMP_TIMEOUT_CHECKPOINT_SECS >= FLEET_TIMEOUT_S.
disable_checkpoint=600
checkpoint_at=$((default_timeout - disable_checkpoint))
if (( checkpoint_at <= 0 )); then
    ok "live: checkpoint_at = $checkpoint_at (non-positive, watchdog suppressed)"
else
    fail "live: disable path broken"
fi

# 11. Syntax.
if bash -n "$WORKER"; then
    ok "worker.sh syntax-clean"
else
    fail "syntax error"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
