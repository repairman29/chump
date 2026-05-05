#!/usr/bin/env bash
# test-fleet-session-id-isolation.sh — INFRA-461
#
# Verifies that fleet workers DO NOT stomp the operator's interactive
# session lease. The bug: worker.sh ran with cwd=$REPO_ROOT (the main
# worktree), so any chump/coord subprocess walking the session-ID
# resolution chain in gap-claim.sh fell through to
# .chump-locks/.wt-session-id — which holds the operator's interactive
# session ID. Every fleet worker then wrote leases under that one ID,
# stomping each other AND the operator.
#
# The fix: worker.sh exports a unique CHUMP_SESSION_ID at startup,
# derived from FLEET_SESSION + AGENT_ID + PID + epoch.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
RUN_FLEET="$REPO_ROOT/scripts/dispatch/run-fleet.sh"

[[ -f "$WORKER" ]]    || { echo "FATAL: worker.sh missing"; exit 2; }
[[ -f "$RUN_FLEET" ]] || { echo "FATAL: run-fleet.sh missing"; exit 2; }

echo "=== INFRA-461 fleet session-ID isolation test ==="
echo

# --- Test 1: worker.sh exports CHUMP_SESSION_ID early (before the loop) ---
if grep -qE 'export CHUMP_SESSION_ID="fleet-' "$WORKER"; then
    ok "worker.sh exports a unique CHUMP_SESSION_ID at startup"
else
    fail "worker.sh does NOT export CHUMP_SESSION_ID — would inherit .wt-session-id"
fi

# --- Test 2: run-fleet.sh passes FLEET_SESSION to worker panes ---
if grep -qE '"FLEET_SESSION=\$FLEET_SESSION"' "$RUN_FLEET"; then
    ok "run-fleet.sh passes FLEET_SESSION to worker panes"
else
    fail "run-fleet.sh does NOT pass FLEET_SESSION to workers — derived ID would be ambiguous"
fi

# --- Test 3: worker.sh's exported ID embeds AGENT_ID + PID for uniqueness ---
WORKER_LINE=$(grep -E 'export CHUMP_SESSION_ID="fleet-' "$WORKER" | head -1)
if [[ "$WORKER_LINE" == *'AGENT_ID'* ]] && [[ "$WORKER_LINE" == *'$$'* ]]; then
    ok "session ID includes AGENT_ID and PID (siblings can't collide)"
else
    fail "session ID missing AGENT_ID or PID — sibling workers could still collide"
fi

# --- Test 4: live simulation — sourcing worker.sh's prelude DOES set the ID ---
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Extract just the prelude (everything up to but not including the main loop /
# function defs) — easiest approach: source worker.sh in a subshell after
# overriding `set -uo pipefail` to no-op, and have it bail before the loop.
# Simpler: just run a tiny snippet that mimics the export logic.
SNIPPET="$TMPDIR_BASE/prelude.sh"
# Pull out the env-default block + the export logic. We accept anything from
# 'AGENT_ID="${AGENT_ID:-?}"' through the closing 'fi' of the export-if.
awk '/^AGENT_ID="\$\{AGENT_ID:-\?\}"/,/^fi$/' "$WORKER" > "$SNIPPET"

# Sanity: snippet should contain the export line.
if ! grep -q 'export CHUMP_SESSION_ID' "$SNIPPET"; then
    fail "could not extract worker.sh prelude for live test (skipping)"
else
    # Run it twice with different AGENT_IDs to verify session IDs differ.
    # Unset CHUMP_SESSION_ID in the test subshell — the parent (e.g.
    # bot-merge.sh) may have set it, and the export-if would short-circuit.
    ID_A=$(env -u CHUMP_SESSION_ID AGENT_ID=1 FLEET_SESSION=test-fleet bash -c "source '$SNIPPET'; echo \$CHUMP_SESSION_ID")
    ID_B=$(env -u CHUMP_SESSION_ID AGENT_ID=2 FLEET_SESSION=test-fleet bash -c "source '$SNIPPET'; echo \$CHUMP_SESSION_ID")

    if [[ -n "$ID_A" ]] && [[ -n "$ID_B" ]] && [[ "$ID_A" != "$ID_B" ]]; then
        ok "two workers in same fleet get distinct session IDs ($ID_A vs $ID_B)"
    else
        fail "expected distinct IDs; got A='$ID_A' B='$ID_B'"
    fi

    # And neither should match the operator's worktree-scoped ID pattern
    # (chump-<reponame>-<digits>).
    if [[ "$ID_A" =~ ^chump-Chump-[0-9]+ ]] || [[ "$ID_A" =~ ^chump-[A-Za-z]+-[0-9]+$ ]]; then
        fail "fleet session ID matches operator pattern: $ID_A — would stomp"
    else
        ok "fleet session ID does NOT match operator-worktree pattern"
    fi
fi

# --- Test 5: pre-existing CHUMP_SESSION_ID is honored (no clobber) ---
PRESET=$(CHUMP_SESSION_ID=preset-id-123 AGENT_ID=1 FLEET_SESSION=test-fleet bash -c "source '$SNIPPET'; echo \$CHUMP_SESSION_ID")
if [[ "$PRESET" == "preset-id-123" ]]; then
    ok "explicit CHUMP_SESSION_ID is honored (no clobber)"
else
    fail "explicit CHUMP_SESSION_ID was clobbered to '$PRESET' — should have been preset-id-123"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
