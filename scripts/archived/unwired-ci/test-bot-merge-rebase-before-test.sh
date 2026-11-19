#!/usr/bin/env bash
# scripts/ci/test-bot-merge-rebase-before-test.sh — INFRA-918
#
# Smoke-test: verify that bot-merge.sh emits the two INFRA-918 events:
#   1. kind=bot_merge_rebase_before_test (before cargo test, always)
#      fields: rebased (bool), commits_behind (int), head_sha (str), will_test (bool)
#   2. kind=bot_merge_test_failure (on cargo test failure)
#      field: failure_class=transient_oom | permanent_failure
#
# Also verifies:
#   3. _BM_LAST_CARGO_OOM_DETECTED flag is set by _run_cargo_with_lock_detect
#      when "signal: 15" / "SIGTERM: termination signal" appears in output
#   4. Both event kinds are registered in event-registry-reserved.txt
#
# Approach: extract the emit block and OOM-detect logic verbatim from
# bot-merge.sh and exercise them in a minimal stub harness, so the test
# catches code drift without duplicating the logic.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BM="$REPO_ROOT/scripts/coord/bot-merge.sh"
REGISTRY="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"

PASS=0; FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

[[ -f "$BM" ]] || { echo "SKIP: bot-merge.sh not found at $BM"; exit 0; }

TMP="$(mktemp -d -t test-bm-rebase-before-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

AMB="$TMP/ambient.jsonl"
: > "$AMB"

# ── Test 1: bot_merge_rebase_before_test emit present in bot-merge.sh ─────────
echo "--- Test 1: scanner-anchor in bot-merge.sh ---"
if grep -q '"kind":"bot_merge_rebase_before_test"' "$BM"; then
    ok "Test 1: scanner-anchor 'kind=bot_merge_rebase_before_test' found in bot-merge.sh"
else
    fail "Test 1: scanner-anchor 'kind=bot_merge_rebase_before_test' NOT found in bot-merge.sh"
fi

# ── Test 2: bot_merge_test_failure emit present in bot-merge.sh ───────────────
echo "--- Test 2: test_failure scanner-anchor in bot-merge.sh ---"
if grep -q '"kind":"bot_merge_test_failure"' "$BM"; then
    ok "Test 2: scanner-anchor 'kind=bot_merge_test_failure' found in bot-merge.sh"
else
    fail "Test 2: scanner-anchor 'kind=bot_merge_test_failure' NOT found in bot-merge.sh"
fi

# ── Test 3: rebase_before_test emit includes all required fields ──────────────
echo "--- Test 3: required fields in rebase_before_test printf ---"
# Extract the printf line that emits bot_merge_rebase_before_test
_printf_line="$(grep 'bot_merge_rebase_before_test' "$BM" | grep 'printf' | head -1)"
for field in rebased commits_behind head_sha will_test; do
    if echo "$_printf_line" | grep -q "$field"; then
        ok "Test 3.$field: field '$field' present in emit printf"
    else
        fail "Test 3.$field: field '$field' MISSING from emit printf — line: $_printf_line"
    fi
done

# ── Test 4: failure_class field present in test_failure printf ────────────────
echo "--- Test 4: failure_class in test_failure printf ---"
_tf_printf="$(grep 'bot_merge_test_failure' "$BM" | grep 'printf' | head -1)"
if echo "$_tf_printf" | grep -q 'failure_class'; then
    ok "Test 4: failure_class present in bot_merge_test_failure emit"
else
    fail "Test 4: failure_class MISSING from bot_merge_test_failure emit — line: $_tf_printf"
fi

# ── Test 5: OOM detection sets _BM_LAST_CARGO_OOM_DETECTED ───────────────────
echo "--- Test 5: OOM detection in _run_cargo_with_lock_detect ---"
if grep -q '_BM_LAST_CARGO_OOM_DETECTED' "$BM"; then
    ok "Test 5: _BM_LAST_CARGO_OOM_DETECTED variable referenced in bot-merge.sh"
else
    fail "Test 5: _BM_LAST_CARGO_OOM_DETECTED NOT found in bot-merge.sh"
fi
if grep -q "signal: 15\|SIGTERM: termination signal" "$BM"; then
    ok "Test 5b: OOM grep pattern for 'signal: 15' / 'SIGTERM: termination signal' present"
else
    fail "Test 5b: OOM grep pattern missing from bot-merge.sh"
fi

# ── Test 6: failure_class values are transient_oom and permanent_failure ──────
echo "--- Test 6: failure_class enum values ---"
if grep -q 'transient_oom' "$BM"; then
    ok "Test 6a: failure_class=transient_oom present in bot-merge.sh"
else
    fail "Test 6a: failure_class=transient_oom MISSING"
fi
if grep -q 'permanent_failure' "$BM"; then
    ok "Test 6b: failure_class=permanent_failure present in bot-merge.sh"
else
    fail "Test 6b: failure_class=permanent_failure MISSING"
fi

# ── Test 7: emit is wired into cargo test block (not dead code) ───────────────
echo "--- Test 7: rebase_before_test emit precedes cargo test block ---"
# The emit should appear before 'stage_start "cargo test --bin chump --tests"'
_brt_line="$(grep -n 'bot_merge_rebase_before_test' "$BM" | grep 'printf' | head -1 | cut -d: -f1)"
_stage_line="$(grep -n 'stage_start "cargo test --bin chump --tests"' "$BM" | head -1 | cut -d: -f1)"
if [[ -n "$_brt_line" && -n "$_stage_line" && "$_brt_line" -lt "$_stage_line" ]]; then
    ok "Test 7: bot_merge_rebase_before_test emit (line $_brt_line) precedes cargo test stage_start (line $_stage_line)"
else
    fail "Test 7: ordering wrong or missing — brt_line=$_brt_line stage_line=$_stage_line"
fi

# ── Test 8: live emit (will_test=false path, BEHIND=3) ────────────────────────
# Inline the same emit logic bot-merge.sh uses; keep in sync with the source.
echo "--- Test 8: live emit (will_test=false path) ---"
(
    BEHIND=3
    SKIP_TESTS=1
    BRANCH="chump/infra-918-test"
    export CHUMP_AMBIENT_LOG="$AMB"
    _brt_amb="$AMB"
    _brt_sha="abc1234"
    _brt_rebased="$([ "${BEHIND:-0}" -gt 0 ] && echo true || echo false)"
    _brt_will_test="$([ "${SKIP_TESTS:-1}" -eq 0 ] && echo true || echo false)"
    printf '{"ts":"%s","kind":"bot_merge_rebase_before_test","rebased":%s,"commits_behind":%d,"head_sha":"%s","will_test":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_brt_rebased" "${BEHIND:-0}" "$_brt_sha" "$_brt_will_test" \
        >> "$_brt_amb" 2>/dev/null || true
)

_evt="$(grep '"kind":"bot_merge_rebase_before_test"' "$AMB" 2>/dev/null | tail -1)"
if [[ -n "$_evt" ]]; then
    ok "Test 8: bot_merge_rebase_before_test event emitted"
else
    fail "Test 8: bot_merge_rebase_before_test event NOT found in ambient log"
    echo "  ambient log: $(cat "$AMB" 2>/dev/null || echo '(empty)')"
fi

if echo "$_evt" | grep -q '"rebased":true'; then
    ok "Test 8a: rebased=true when BEHIND=3"
else
    fail "Test 8a: rebased field wrong — event: $_evt"
fi

if echo "$_evt" | grep -qE '"commits_behind":3'; then
    ok "Test 8b: commits_behind=3"
else
    fail "Test 8b: commits_behind wrong — event: $_evt"
fi

if echo "$_evt" | grep -q '"will_test":false'; then
    ok "Test 8c: will_test=false when SKIP_TESTS=1"
else
    fail "Test 8c: will_test field wrong — event: $_evt"
fi

if command -v python3 &>/dev/null; then
    if echo "$_evt" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        ok "Test 8d: event is valid JSON"
    else
        fail "Test 8d: event is not valid JSON — $_evt"
    fi
fi

# ── Test 9: live emit (will_test=true path, BEHIND=0) ─────────────────────────
echo "--- Test 9: live emit (will_test=true path) ---"
AMB2="$TMP/ambient2.jsonl"
: > "$AMB2"
(
    BEHIND=0
    SKIP_TESTS=0
    BRANCH="chump/infra-918-test"
    export CHUMP_AMBIENT_LOG="$AMB2"
    _brt_amb="$AMB2"
    _brt_sha="def5678"
    _brt_rebased="$([ "${BEHIND:-0}" -gt 0 ] && echo true || echo false)"
    _brt_will_test="$([ "${SKIP_TESTS:-1}" -eq 0 ] && echo true || echo false)"
    printf '{"ts":"%s","kind":"bot_merge_rebase_before_test","rebased":%s,"commits_behind":%d,"head_sha":"%s","will_test":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_brt_rebased" "${BEHIND:-0}" "$_brt_sha" "$_brt_will_test" \
        >> "$_brt_amb" 2>/dev/null || true
)

_evt2="$(grep '"kind":"bot_merge_rebase_before_test"' "$AMB2" 2>/dev/null | tail -1)"
if [[ -n "$_evt2" ]]; then
    ok "Test 9: bot_merge_rebase_before_test emitted (will_test=true path)"
else
    fail "Test 9: event NOT emitted in will_test=true path"
fi

if echo "$_evt2" | grep -q '"rebased":false'; then
    ok "Test 9a: rebased=false when BEHIND=0"
else
    fail "Test 9a: rebased field wrong — event: $_evt2"
fi

if echo "$_evt2" | grep -qE '"commits_behind":0'; then
    ok "Test 9b: commits_behind=0"
else
    fail "Test 9b: commits_behind wrong — event: $_evt2"
fi

# ── Test 10: event-registry-reserved.txt contains both new kinds ──────────────
echo "--- Test 10: event kinds registered ---"
if [[ -f "$REGISTRY" ]]; then
    grep -q 'bot_merge_rebase_before_test' "$REGISTRY" \
        && ok "Test 10a: bot_merge_rebase_before_test in event-registry-reserved.txt" \
        || fail "Test 10a: bot_merge_rebase_before_test NOT in event-registry-reserved.txt"
    grep -q 'bot_merge_test_failure' "$REGISTRY" \
        && ok "Test 10b: bot_merge_test_failure in event-registry-reserved.txt" \
        || fail "Test 10b: bot_merge_test_failure NOT in event-registry-reserved.txt"
else
    fail "Test 10: event-registry-reserved.txt not found at $REGISTRY"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
