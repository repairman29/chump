#!/usr/bin/env bash
# test-fleet-pid-invariant.sh — INFRA-649
#
# Tests for `chump fleet audit-pids [--apply]` covering:
#   1. Invariant satisfied (no drift) → action=ok, no side effects
#   2. PIDs > expected+1 (orphan excess) → action=drift (report), pruned (apply)
#   3. PIDs < expected-1 (deficit/missing workers) → action=drift (report), respawned (apply)
#   4. Within ±1 tolerance (transient wrapper spawn) → action=ok
#
# Strategy: stub pgrep to return controlled counts, then parse ambient.jsonl
# to verify the emitted event matches expectations.

set -euo pipefail

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; ((PASS++)); }
fail() { echo "  FAIL: $1"; ((FAIL++)); }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
BIN="$REPO_ROOT/bin/chump"

# Skip if binary not built yet.
if [[ ! -x "$BIN" ]]; then
    echo "[skip] $BIN not found — run 'cargo build' first"
    exit 0
fi

# Isolated temp environment.
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

setup_env() {
    local worker_count="$1"
    local pgrep_count="$2"

    local dir="$TMPDIR_BASE/env-$$-$RANDOM"
    mkdir -p "$dir/.chump-locks" "$dir/.chump" "$dir/bin"

    echo "$worker_count" > "$dir/.chump/fleet-desired-size"
    touch "$dir/.chump-locks/ambient.jsonl"

    # Stub pgrep: always returns the controlled count regardless of args.
    cat > "$dir/bin/pgrep" <<STUB
#!/bin/bash
# stub: returns fixed count for -c -f pattern
echo "$pgrep_count"
exit 0
STUB
    chmod +x "$dir/bin/pgrep"

    # Stub pkill: no-op, records invocation.
    cat > "$dir/bin/pkill" <<STUB
#!/bin/bash
echo "pkill-called" >> "$dir/pkill-calls.txt"
exit 0
STUB
    chmod +x "$dir/bin/pkill"

    # Stub fleet-restart.sh: no-op, records invocation.
    mkdir -p "$dir/scripts/dispatch"
    cat > "$dir/scripts/dispatch/fleet-restart.sh" <<STUB
#!/bin/bash
echo "fleet-restart-called size=\$FLEET_SIZE" >> "$dir/restart-calls.txt"
exit 0
STUB
    chmod +x "$dir/scripts/dispatch/fleet-restart.sh"

    echo "$dir"
}

last_event() {
    local dir="$1"
    tail -1 "$dir/.chump-locks/ambient.jsonl" 2>/dev/null || echo "{}"
}

run_audit() {
    local dir="$1"
    shift
    # PATH manipulation so our stubs take precedence.
    PATH="$dir/bin:$PATH" REPO_ROOT="$dir" "$BIN" fleet audit-pids "$@" 2>&1 || true
}

# ---------------------------------------------------------------------------
# Case 1: Invariant satisfied — worker_count=2, expected=4, actual=4
# ---------------------------------------------------------------------------
echo ""
echo "Case 1: Invariant satisfied (actual=4 == expected=4)"
DIR1="$(setup_env 2 4)"
run_audit "$DIR1"
EVENT1="$(last_event "$DIR1")"
if echo "$EVENT1" | grep -q '"action":"ok"'; then
    pass "action=ok emitted"
else
    fail "expected action=ok, got: $EVENT1"
fi
if echo "$EVENT1" | grep -q '"kind":"fleet_pid_invariant"'; then
    pass "event kind=fleet_pid_invariant"
else
    fail "missing kind=fleet_pid_invariant: $EVENT1"
fi
if [[ ! -f "$DIR1/pkill-calls.txt" ]]; then
    pass "no pkill called"
else
    fail "pkill was unexpectedly called"
fi

# ---------------------------------------------------------------------------
# Case 2a: PIDs > expected+1, no --apply → report drift only
# ---------------------------------------------------------------------------
echo ""
echo "Case 2a: Excess PIDs (actual=8 > expected=4+1), report only"
DIR2a="$(setup_env 2 8)"
run_audit "$DIR2a"
EVENT2a="$(last_event "$DIR2a")"
if echo "$EVENT2a" | grep -q '"action":"drift"'; then
    pass "action=drift (no --apply)"
else
    fail "expected action=drift, got: $EVENT2a"
fi
if [[ ! -f "$DIR2a/pkill-calls.txt" ]]; then
    pass "no pkill without --apply"
else
    fail "pkill should not fire without --apply"
fi

# ---------------------------------------------------------------------------
# Case 2b: PIDs > expected+1, with --apply → prune orphans
# ---------------------------------------------------------------------------
echo ""
echo "Case 2b: Excess PIDs (actual=8 > expected=4+1), --apply prunes"
DIR2b="$(setup_env 2 8)"
run_audit "$DIR2b" --apply
EVENT2b="$(last_event "$DIR2b")"
if echo "$EVENT2b" | grep -q '"action":"pruned"'; then
    pass "action=pruned"
else
    fail "expected action=pruned, got: $EVENT2b"
fi
if [[ -f "$DIR2b/pkill-calls.txt" ]]; then
    pass "pkill was called"
else
    fail "pkill should be called when pruning"
fi

# ---------------------------------------------------------------------------
# Case 3a: PIDs < expected-1, no --apply → report drift only
# ---------------------------------------------------------------------------
echo ""
echo "Case 3a: Deficit PIDs (actual=1 < expected=4-1), report only"
DIR3a="$(setup_env 2 1)"
run_audit "$DIR3a"
EVENT3a="$(last_event "$DIR3a")"
if echo "$EVENT3a" | grep -q '"action":"drift"'; then
    pass "action=drift (no --apply)"
else
    fail "expected action=drift, got: $EVENT3a"
fi
if [[ ! -f "$DIR3a/restart-calls.txt" ]]; then
    pass "no respawn without --apply"
else
    fail "respawn should not fire without --apply"
fi

# ---------------------------------------------------------------------------
# Case 3b: PIDs < expected-1, with --apply → respawn workers
# ---------------------------------------------------------------------------
echo ""
echo "Case 3b: Deficit PIDs (actual=1 < expected=4-1), --apply respawns"
DIR3b="$(setup_env 2 1)"
run_audit "$DIR3b" --apply
EVENT3b="$(last_event "$DIR3b")"
if echo "$EVENT3b" | grep -q '"action":"respawned"'; then
    pass "action=respawned"
else
    fail "expected action=respawned, got: $EVENT3b"
fi
if [[ -f "$DIR3b/restart-calls.txt" ]]; then
    pass "fleet-restart called for respawn"
else
    fail "fleet-restart.sh should be called when respawning"
fi

# ---------------------------------------------------------------------------
# Case 4: Within ±1 tolerance (transient wrapper spawn)
# ---------------------------------------------------------------------------
echo ""
echo "Case 4: Within ±1 tolerance (actual=5, expected=4, delta=+1)"
DIR4="$(setup_env 2 5)"
run_audit "$DIR4"
EVENT4="$(last_event "$DIR4")"
if echo "$EVENT4" | grep -q '"action":"ok"'; then
    pass "action=ok within tolerance"
else
    fail "expected action=ok for delta=+1, got: $EVENT4"
fi
if echo "$EVENT4" | grep -q '"delta":1'; then
    pass "delta=1 recorded"
else
    fail "delta should be 1, got: $EVENT4"
fi

# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
