#!/usr/bin/env bash
# test-node-install-async-phases.sh — RESILIENT-1015
#
# Regression test for the COTG node-install fix that stops SUBSTRATE/EYES
# from stalling the one-shot install (verified repro: mugman, 2-core
# aarch64, hung past BINARY with the binary pre-placed + fetch disabled —
# the actual stall was a downstream synchronous phase, not BINARY).
#
# Guards three properties of scripts/setup/chump-node-install.sh:
#   1. run_timeout actually bounds a runaway subprocess instead of hanging.
#   2. run_phase_async returns control to the caller immediately even when
#      the wrapped script sleeps far longer than the caller waits — i.e. the
#      phase is genuinely backgrounded, not just fire-and-forget-but-still-
#      blocking.
#   3. run_phase_async's pending marker exists while the background job is
#      running and is removed once it exits — the signal self_test reads to
#      avoid hard-failing on "still provisioning".
#
# Network-free + deterministic: sources the installer (top-level run is
# guarded by BASH_SOURCE!=$0) and drives the functions directly with a fake
# slow script. Fails without the fix (old code called the phase script with
# a blocking `bash "$script"`, so this test's step 2 would take as long as
# the slow script's sleep instead of returning immediately).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/setup/chump-node-install.sh"
[ -f "$INSTALLER" ] || { echo "FAIL: installer not found: $INSTALLER"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-async-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export CHUMP_NODE_DIR="$TMP/node"
export CHUMP_STATE_DIR="$TMP/state"
mkdir -p "$CHUMP_NODE_DIR/bin" "$CHUMP_STATE_DIR"

fails=0
pass(){ printf '  ok   %s\n' "$*"; }
fail(){ printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }

# Source the installer without triggering an install run (BASH_SOURCE guard).
set --
# shellcheck disable=SC1090
. "$INSTALLER"

# ---- 1. run_timeout bounds a runaway subprocess ----
t0=$SECONDS
if run_timeout 1 sleep 30; then
  fail "run_timeout 1 sleep 30 did not time out (returned success)"
else
  elapsed=$((SECONDS - t0))
  if [ "$elapsed" -le 5 ]; then pass "run_timeout enforces a ceiling (killed sleep 30 after ${elapsed}s)"
  else fail "run_timeout took ${elapsed}s to kill sleep 30 (expected <=5s)"; fi
fi

# ---- 2. run_phase_async does not block the caller ----
SLOW_SCRIPT="$TMP/slow-phase.sh"
cat > "$SLOW_SCRIPT" <<'EOF'
#!/usr/bin/env bash
sleep 10
echo done
EOF
chmod +x "$SLOW_SCRIPT"
LOG_DIR="$TMP/logs"; STATE_DIR="$CHUMP_STATE_DIR"
mkdir -p "$LOG_DIR"

t0=$SECONDS
run_phase_async testphase 60 "$SLOW_SCRIPT" "$LOG_DIR/testphase.log"
elapsed=$((SECONDS - t0))
if [ "$elapsed" -le 3 ]; then pass "run_phase_async returned immediately (${elapsed}s) despite a 10s phase script"
else fail "run_phase_async blocked the caller for ${elapsed}s (expected <=3s) — phase is not actually async"
fi

# ---- 3. pending marker present while running, gone once the job exits ----
if [ -f "$STATE_DIR/.testphase.pending" ]; then
  pass "pending marker exists while background phase runs"
else
  fail "pending marker missing immediately after launch (self_test can't distinguish pending from failed)"
fi

# Wait past the phase's 10s sleep + a margin, then confirm cleanup.
waited=0
while [ -f "$STATE_DIR/.testphase.pending" ] && [ "$waited" -lt 15 ]; do
  sleep 1; waited=$((waited+1))
done
if [ -f "$STATE_DIR/.testphase.pending" ]; then
  fail "pending marker still present after ${waited}s (background job should have finished)"
else
  pass "pending marker removed once the background phase completed (waited ${waited}s)"
fi
if [ -f "$LOG_DIR/testphase.log" ] && grep -q done "$LOG_DIR/testphase.log"; then
  pass "background phase actually ran to completion (log shows 'done')"
else
  fail "background phase log missing/incomplete: $LOG_DIR/testphase.log"
fi

echo
if [ "$fails" -eq 0 ]; then echo "PASS: SUBSTRATE/EYES async-phase guard holds ($0)"; exit 0
else echo "FAIL: $fails assertion(s) failed"; exit 1; fi
