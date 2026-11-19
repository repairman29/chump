#!/usr/bin/env bash
# test-worker-prelude-reads-floor.sh — INFRA-2008
#
# Validates that scripts/dispatch/worker.sh's pre-claim prelude actually
# reads THE FLOOR's two signals (floor-temp + fleet-hold) via the shared
# scripts/dispatch/lib/floor-readers.sh helper, exports CHUMP_FLOOR_TEMP /
# CHUMP_FLEET_HOLD for the loop and any spawned subagent, and pivots
# correctly on HOT / hold-active.
#
# Two layers:
#  1. Static — worker.sh sources the lib and reacts to the exported vars.
#  2. Functional — synthesize an ambient.jsonl with 3 HOT-class events
#     (forces `chump health --temp` to HOT) and a fleet-hold.txt, source
#     floor-readers.sh directly, and assert the exported env vars +
#     emitted worker_floor_signal_read events are correct.

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
LIB="$REPO_ROOT/scripts/dispatch/lib/floor-readers.sh"

echo "=== INFRA-2008 worker prelude / floor-signal test ==="
echo

# ── Static checks ───────────────────────────────────────────────────────

if [[ -f "$LIB" ]]; then
    ok "scripts/dispatch/lib/floor-readers.sh exists"
else
    fail "scripts/dispatch/lib/floor-readers.sh missing"
fi

if grep -q 'chump_read_floor_signals' "$LIB" 2>/dev/null; then
    ok "floor-readers.sh defines chump_read_floor_signals()"
else
    fail "chump_read_floor_signals() missing from floor-readers.sh"
fi

if grep -q 'source.*floor-readers.sh' "$WORKER"; then
    ok "worker.sh sources floor-readers.sh"
else
    fail "worker.sh does not source floor-readers.sh"
fi

if grep -q 'chump_read_floor_signals "\$REPO_ROOT" "\$AGENT_ID"' "$WORKER"; then
    ok "worker.sh calls chump_read_floor_signals before claim"
else
    fail "worker.sh does not call chump_read_floor_signals"
fi

if grep -q 'CHUMP_FLEET_HOLD.*==.*"true"' "$WORKER"; then
    ok "worker.sh pivots on CHUMP_FLEET_HOLD=true"
else
    fail "worker.sh missing CHUMP_FLEET_HOLD pivot branch"
fi

if grep -q 'CHUMP_FLOOR_TEMP.*==.*"HOT"' "$WORKER"; then
    ok "worker.sh narrows effort on CHUMP_FLOOR_TEMP=HOT"
else
    fail "worker.sh missing CHUMP_FLOOR_TEMP HOT branch"
fi

if grep -q 'CHUMP_FLEET_HOLD\|CHUMP_FLOOR_TEMP' "$REPO_ROOT/docs/process/SUBAGENT_DISPATCH.md" 2>/dev/null; then
    ok "SUBAGENT_DISPATCH.md documents the floor-signal env vars"
else
    fail "SUBAGENT_DISPATCH.md missing floor-signal env var contract"
fi

# ── Functional checks ───────────────────────────────────────────────────

CHUMP_BIN="$(command -v chump || true)"
for _cand in "$REPO_ROOT/target/debug/chump" "$REPO_ROOT/target/release/chump"; do
    if [[ -z "$CHUMP_BIN" && -x "$_cand" ]]; then
        CHUMP_BIN="$_cand"
    fi
done

if [[ -z "$CHUMP_BIN" ]]; then
    echo "  SKIP: no chump binary found (not built) — skipping functional checks"
else
    TMPDIR_T="$(mktemp -d -t infra2008-XXXXXX)"
    trap 'rm -rf "$TMPDIR_T"' EXIT

    AMBIENT="$TMPDIR_T/ambient.jsonl"
    HOLD_FILE="$TMPDIR_T/fleet-hold.txt"
    NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # 3 distinct HOT_EVENT_KINDS in-window → chump health --temp should be HOT.
    {
        printf '{"ts":"%s","kind":"hook_silent_passthrough","source":"test"}\n' "$NOW"
        printf '{"ts":"%s","kind":"ci_failure_cluster","source":"test"}\n' "$NOW"
        printf '{"ts":"%s","kind":"admin_merge_executed","source":"test"}\n' "$NOW"
    } > "$AMBIENT"

    echo '{"active":true,"reason":"test-synthesized"}' > "$HOLD_FILE"

    # shellcheck source=/dev/null
    source "$LIB"

    OUT_AMBIENT="$TMPDIR_T/worker-events.jsonl"
    : > "$OUT_AMBIENT"

    (
        export CHUMP_AMBIENT_LOG="$AMBIENT"
        export CHUMP_FLEET_HOLD_FILE="$HOLD_FILE"
        export PATH="$(dirname "$CHUMP_BIN"):$PATH"
        chump_read_floor_signals "$REPO_ROOT" "test-agent" "$OUT_AMBIENT"
        printf '%s\n' "$CHUMP_FLOOR_TEMP" > "$TMPDIR_T/temp.out"
        printf '%s\n' "$CHUMP_FLEET_HOLD" > "$TMPDIR_T/hold.out"
    )

    GOT_TEMP="$(cat "$TMPDIR_T/temp.out" 2>/dev/null || echo '?')"
    GOT_HOLD="$(cat "$TMPDIR_T/hold.out" 2>/dev/null || echo '?')"

    if [[ "$GOT_TEMP" == "HOT" ]]; then
        ok "CHUMP_FLOOR_TEMP=HOT exported for a synthesized 3-hot-event ambient log"
    else
        fail "expected CHUMP_FLOOR_TEMP=HOT, got '$GOT_TEMP'"
    fi

    if [[ "$GOT_HOLD" == "true" ]]; then
        ok "CHUMP_FLEET_HOLD=true exported when fleet-hold.txt present"
    else
        fail "expected CHUMP_FLEET_HOLD=true, got '$GOT_HOLD'"
    fi

    if grep -q '"kind":"worker_floor_signal_read".*"signal":"fleet_hold"' "$OUT_AMBIENT" 2>/dev/null; then
        ok "worker_floor_signal_read (fleet_hold) emitted"
    else
        fail "worker_floor_signal_read (fleet_hold) not emitted"
    fi

    if grep -q '"kind":"worker_floor_signal_read".*"signal":"floor_temp"' "$OUT_AMBIENT" 2>/dev/null; then
        ok "worker_floor_signal_read (floor_temp) emitted"
    else
        fail "worker_floor_signal_read (floor_temp) not emitted"
    fi

    # COLD / no-hold case.
    : > "$AMBIENT"
    rm -f "$HOLD_FILE"
    (
        export CHUMP_AMBIENT_LOG="$AMBIENT"
        export CHUMP_FLEET_HOLD_FILE="$HOLD_FILE"
        export PATH="$(dirname "$CHUMP_BIN"):$PATH"
        chump_read_floor_signals "$REPO_ROOT" "test-agent" "$OUT_AMBIENT"
        printf '%s\n' "$CHUMP_FLOOR_TEMP" > "$TMPDIR_T/temp2.out"
        printf '%s\n' "$CHUMP_FLEET_HOLD" > "$TMPDIR_T/hold2.out"
    )
    GOT_TEMP2="$(cat "$TMPDIR_T/temp2.out" 2>/dev/null || echo '?')"
    GOT_HOLD2="$(cat "$TMPDIR_T/hold2.out" 2>/dev/null || echo '?')"

    if [[ "$GOT_TEMP2" == "COLD" ]]; then
        ok "CHUMP_FLOOR_TEMP=COLD exported for an empty ambient log"
    else
        fail "expected CHUMP_FLOOR_TEMP=COLD, got '$GOT_TEMP2'"
    fi

    if [[ "$GOT_HOLD2" == "false" ]]; then
        ok "CHUMP_FLEET_HOLD=false exported when fleet-hold.txt absent"
    else
        fail "expected CHUMP_FLEET_HOLD=false, got '$GOT_HOLD2'"
    fi
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
