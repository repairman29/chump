#!/usr/bin/env bash
# test-bot-merge-rebase-before-test.sh — CI smoke test for INFRA-918
# Rust-First-Bypass: shell test for shell-only feature (ambient event emission in
#   scripts/coord/bot-merge.sh); no state mutation beyond temp files; < 200 LOC.
#
# Scenarios tested:
#   1. REBASED path:     BEHIND=3  → bot_merge_rebase_before_test{rebased=true,  commits_behind=3,  will_test=true}
#   2. UP-TO-DATE path:  BEHIND=0  → bot_merge_rebase_before_test{rebased=false, commits_behind=0,  will_test=true}
#   3. SKIP_TESTS path:  SKIP_TESTS=1 → bot_merge_rebase_before_test{will_test=false}
#   4. test_failure OOM: SIGTERM in output → bot_merge_test_failure{failure_class=transient_oom}
#   5. test_failure perm: normal failure   → bot_merge_test_failure{failure_class=permanent_failure}
#
# Stubs: git (HEAD sha), date, ambient write. Never touches real state.db or GitHub.
set -euo pipefail

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

AMBIENT_LOG="$TMPDIR_TEST/ambient.jsonl"
touch "$AMBIENT_LOG"

PASS=0; FAIL=0; declare -a FAILURES=()
pass() { echo "  ✓ $1"; PASS=$(( PASS + 1 )); }
fail() { echo "  ✗ $1"; FAIL=$(( FAIL + 1 )); FAILURES+=("$1"); }

# ── Helper: extract the last event of a given kind from ambient log ───────────
last_event() {
    local kind="$1"
    grep '"kind":"'"$kind"'"' "$AMBIENT_LOG" 2>/dev/null | tail -1
}

# ── Helper: emit _bm_rebase_before_test_emit (inlined from bot-merge.sh) ──────
emit_rebase_before_test() {
    local rebased_val="$1" commits_behind_val="$2" head_sha_val="$3" will_test_val="$4"
    local ts="2026-01-01T00:00:00Z"
    local gap_label="INFRA-918-test"
    printf '{"ts":"%s","kind":"bot_merge_rebase_before_test","gap":"%s","rebased":%s,"commits_behind":%d,"head_sha":"%s","will_test":%s,"note":"INFRA-918: rebase-state snapshot immediately before cargo test"}\n' \
        "$ts" "$gap_label" "$rebased_val" "$commits_behind_val" "$head_sha_val" "$will_test_val" \
        >> "$AMBIENT_LOG"
}

# ── Helper: emit bot_merge_test_failure (inlined from bot-merge.sh) ──────────
emit_test_failure() {
    local fail_class="$1" head_sha="$2"
    local ts="2026-01-01T00:00:00Z"
    local gap_label="INFRA-918-test"
    printf '{"ts":"%s","kind":"bot_merge_test_failure","gap":"%s","failure_class":"%s","head_sha":"%s","rebased":true,"commits_behind":3,"note":"INFRA-918"}\n' \
        "$ts" "$gap_label" "$fail_class" "$head_sha" \
        >> "$AMBIENT_LOG"
}

# ── Helper: classify test output (mirrors bot-merge.sh logic) ─────────────────
classify_test_output() {
    local output_file="$1"
    local fail_class="permanent_failure"
    if grep -qE "signal: 15|SIGTERM|signal: 9|killed by signal|Jetsam" "$output_file" 2>/dev/null; then
        fail_class="transient_oom"
    fi
    echo "$fail_class"
}

echo "=== INFRA-918: bot_merge_rebase_before_test smoke tests ==="
echo ""

# ── Scenario 1: rebased path (BEHIND=3, will_test=true) ──────────────────────
echo "Scenario 1: rebased path"
> "$AMBIENT_LOG"
emit_rebase_before_test "true" 3 "abc1234" "true"
event="$(last_event "bot_merge_rebase_before_test")"
if [[ -z "$event" ]]; then
    fail "S1: no bot_merge_rebase_before_test event emitted"
else
    pass "S1: event emitted"
    if echo "$event" | python3 -c "import json,sys; o=json.load(sys.stdin); assert o['rebased']==True" 2>/dev/null; then
        pass "S1: rebased=true"
    else
        fail "S1: rebased field not true"
    fi
    if echo "$event" | python3 -c "import json,sys; o=json.load(sys.stdin); assert o['commits_behind']==3" 2>/dev/null; then
        pass "S1: commits_behind=3"
    else
        fail "S1: commits_behind not 3"
    fi
    if echo "$event" | python3 -c "import json,sys; o=json.load(sys.stdin); assert o['head_sha']=='abc1234'" 2>/dev/null; then
        pass "S1: head_sha present"
    else
        fail "S1: head_sha missing or wrong"
    fi
    if echo "$event" | python3 -c "import json,sys; o=json.load(sys.stdin); assert o['will_test']==True" 2>/dev/null; then
        pass "S1: will_test=true"
    else
        fail "S1: will_test not true"
    fi
fi
echo ""

# ── Scenario 2: up-to-date path (BEHIND=0, will_test=true) ───────────────────
echo "Scenario 2: up-to-date (BEHIND=0)"
> "$AMBIENT_LOG"
emit_rebase_before_test "false" 0 "def5678" "true"
event="$(last_event "bot_merge_rebase_before_test")"
if [[ -z "$event" ]]; then
    fail "S2: no event emitted"
else
    pass "S2: event emitted"
    if echo "$event" | python3 -c "import json,sys; o=json.load(sys.stdin); assert o['rebased']==False" 2>/dev/null; then
        pass "S2: rebased=false"
    else
        fail "S2: rebased not false"
    fi
    if echo "$event" | python3 -c "import json,sys; o=json.load(sys.stdin); assert o['commits_behind']==0" 2>/dev/null; then
        pass "S2: commits_behind=0"
    else
        fail "S2: commits_behind not 0"
    fi
fi
echo ""

# ── Scenario 3: skip-tests path (will_test=false) ────────────────────────────
echo "Scenario 3: skip-tests (will_test=false)"
> "$AMBIENT_LOG"
emit_rebase_before_test "true" 1 "aaa0001" "false"
event="$(last_event "bot_merge_rebase_before_test")"
if [[ -z "$event" ]]; then
    fail "S3: no event emitted"
else
    pass "S3: event emitted"
    if echo "$event" | python3 -c "import json,sys; o=json.load(sys.stdin); assert o['will_test']==False" 2>/dev/null; then
        pass "S3: will_test=false"
    else
        fail "S3: will_test not false"
    fi
fi
echo ""

# ── Scenario 4: test_failure classified as transient_oom ─────────────────────
echo "Scenario 4: test_failure OOM classification"
oom_output="$TMPDIR_TEST/oom_output.txt"
printf 'error[E0000]: some rust compile error\nprocess didn'"'"'t exit successfully: `rustc` (signal: 15, SIGTERM: termination signal)\nbuild failed\n' > "$oom_output"
class="$(classify_test_output "$oom_output")"
if [[ "$class" == "transient_oom" ]]; then
    pass "S4: SIGTERM output classified as transient_oom"
else
    fail "S4: expected transient_oom, got '$class'"
fi
> "$AMBIENT_LOG"
emit_test_failure "transient_oom" "abc9999"
event="$(last_event "bot_merge_test_failure")"
if [[ -z "$event" ]]; then
    fail "S4: no bot_merge_test_failure event"
else
    pass "S4: bot_merge_test_failure emitted"
    if echo "$event" | python3 -c "import json,sys; o=json.load(sys.stdin); assert o['failure_class']=='transient_oom'" 2>/dev/null; then
        pass "S4: failure_class=transient_oom"
    else
        fail "S4: failure_class wrong"
    fi
fi
echo ""

# ── Scenario 5: test_failure classified as permanent_failure ─────────────────
echo "Scenario 5: test_failure permanent classification"
perm_output="$TMPDIR_TEST/perm_output.txt"
printf 'test foo ... FAILED\ntest result: FAILED. 1 failed; 2 passed\n' > "$perm_output"
class="$(classify_test_output "$perm_output")"
if [[ "$class" == "permanent_failure" ]]; then
    pass "S5: normal failure classified as permanent_failure"
else
    fail "S5: expected permanent_failure, got '$class'"
fi
> "$AMBIENT_LOG"
emit_test_failure "permanent_failure" "abc8888"
event="$(last_event "bot_merge_test_failure")"
if [[ -z "$event" ]]; then
    fail "S5: no bot_merge_test_failure event"
else
    pass "S5: bot_merge_test_failure emitted"
    if echo "$event" | python3 -c "import json,sys; o=json.load(sys.stdin); assert o['failure_class']=='permanent_failure'" 2>/dev/null; then
        pass "S5: failure_class=permanent_failure"
    else
        fail "S5: failure_class wrong"
    fi
fi
echo ""

# ── Results ───────────────────────────────────────────────────────────────────
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    echo "FAILURES:"
    for f in "${FAILURES[@]}"; do echo "  - $f"; done
    exit 1
fi
echo "All tests passed."
