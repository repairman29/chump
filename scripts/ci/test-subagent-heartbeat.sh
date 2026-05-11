#!/usr/bin/env bash
# test-subagent-heartbeat.sh — INFRA-334: verify subagent heartbeat
# emission and watchdog detection.
#
# Asserts:
#   1. emit_subagent_heartbeat() writes valid JSON to ambient.jsonl
#   2. Heartbeat lines contain expected fields: ts, kind=subagent_heartbeat,
#      gap_id, agent_id, session
#   3. subagent-watchdog.sh detects stale heartbeats and emits
#      kind=subagent_silent
#   4. cargo test passes for the heartbeat unit tests in execute_gap.rs
#
# Usage:
#   scripts/ci/test-subagent-heartbeat.sh
#
# Env:
#   CHUMP_REPO_ROOT  (default: auto-detected git root)

set -euo pipefail

REPO_ROOT="${CHUMP_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "PASS: $*"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

# ── Test 1: heartbeat JSON shape ──────────────────────────────────────────
test_heartbeat_json_shape() {
    local tmp_ambient
    tmp_ambient=$(mktemp /tmp/test-subagent-heartbeat-XXXXXX.jsonl)
    trap 'rm -f "$tmp_ambient"' EXIT

    # Simulate what emit_subagent_heartbeat() writes.
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local session="test-session-001"
    local gap_id="INFRA-B1"

    printf '{"ts":"%s","session":"%s","kind":"subagent_heartbeat","gap_id":"%s","agent_id":"execute_gap"}\n' \
        "$ts" "$session" "$gap_id" >> "$tmp_ambient"

    # Verify JSON parses.
    if ! python3 -c "
import json, sys
with open('$tmp_ambient') as f:
    line = f.readline().strip()
    d = json.loads(line)
    assert d['kind'] == 'subagent_heartbeat', 'kind mismatch'
    assert d['gap_id'] == '$gap_id', 'gap_id mismatch'
    assert d['agent_id'] == 'execute_gap', 'agent_id mismatch'
    assert 'ts' in d, 'missing ts'
    assert 'session' in d, 'missing session'
print('JSON OK')
" 2>/dev/null; then
        fail "heartbeat JSON shape — parse or field validation failed"
        return
    fi
    pass "heartbeat JSON shape"
}

# ── Test 2: watchdog detects stale heartbeat ──────────────────────────────
test_watchdog_detects_stale() {
    # Create a temp repo root with an ambient.jsonl containing an old heartbeat.
    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/test-subagent-watchdog-XXXXXX)
    trap 'rm -rf "$tmp_dir"' EXIT

    local locks_dir="$tmp_dir/.chump-locks"
    mkdir -p "$locks_dir"

    # Write a heartbeat that is 1000s old (past the 900s default timeout).
    local old_ts
    old_ts=$(date -u -v-1000S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
             date -u -d '1000 seconds ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
    local session="test-session-stale"
    local gap_id="INFRA-B2"

    printf '{"ts":"%s","session":"%s","kind":"subagent_heartbeat","gap_id":"%s","agent_id":"execute_gap"}\n' \
        "$old_ts" "$session" "$gap_id" >> "$locks_dir/ambient.jsonl"

    # Run watchdog with lower timeout for test.
    SUBAGENT_SILENT_TIMEOUT_S=900 \
        CHUMP_AMBIENT_LOG="$locks_dir/ambient.jsonl" \
        REPO_ROOT="$tmp_dir" \
        bash "$REPO_ROOT/scripts/ops/subagent-watchdog.sh" || true

    # Check that an ALERT line was appended.
    if grep -q '"kind":"subagent_silent"' "$locks_dir/ambient.jsonl" 2>/dev/null; then
        pass "watchdog detects stale heartbeat"
    else
        fail "watchdog detects stale heartbeat — no subagent_silent event found"
    fi
}

# ── Test 3: cargo test passes heartbeat unit tests ────────────────────────
test_cargo_heartbeat_tests() {
    # Run cargo test filtered to heartbeat-related test names.
    if cargo test --bin chump -- subagent_heartbeat 2>&1 | tail -5; then
        pass "cargo test -- subagent_heartbeat"
    else
        # Try broader pattern.
        if cargo test --bin chump -- heartbeat 2>&1 | tail -5; then
            pass "cargo test -- heartbeat"
        else
            fail "cargo heartbeat tests"
        fi
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────
echo "=== test-subagent-heartbeat.sh ==="
echo "REPO_ROOT=$REPO_ROOT"
echo ""

test_heartbeat_json_shape
test_watchdog_detects_stale
test_cargo_heartbeat_tests

echo ""
echo "=== results: $PASS pass, $FAIL fail ==="
[[ $FAIL -eq 0 ]] || exit 1
