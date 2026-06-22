#!/usr/bin/env bash
# scripts/ci/test-bot-merge-rebase-before-test.sh — INFRA-918
#
# Validates that bot-merge.sh emits the correct ambient events:
#   AC #1  kind=bot_merge_rebase_before_test with required fields before cargo test
#   AC #2  kind=bot_merge_test_failure with failure_class=transient_oom (SIGTERM/OOM)
#          or failure_class=permanent_failure (logic bug)
#   AC #3  phase=cargo test --bin chump --tests in bot_merge_phase_duration
#          is already covered by test-bot-merge-phase-duration.sh + stage_done()
#
# Tests:
#   1. bot_merge_rebase_before_test emitted with rebased=false when up-to-date
#   2. bot_merge_rebase_before_test emitted with rebased=true when BEHIND > 0
#   3. commits_behind field matches BEHIND variable
#   4. head_sha field is non-empty string
#   5. will_test=true when SKIP_TESTS=0 and cargo available
#   6. will_test=false when SKIP_TESTS=1
#   7. bot_merge_test_failure emitted with failure_class=transient_oom on SIGTERM output
#   8. bot_merge_test_failure emitted with failure_class=permanent_failure on logic failure
#   9. All events are valid JSON

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
TMP="$(mktemp -d -t test-bm-rebase-before-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

BM="$REPO_ROOT/scripts/coord/bot-merge.sh"
[[ -f "$BM" ]] || { echo "SKIP: bot-merge.sh not found at $BM"; exit 0; }

AMB_WRITE_LIB="$REPO_ROOT/scripts/coord/lib/ambient-write.sh"
[[ -f "$AMB_WRITE_LIB" ]] || { echo "SKIP: ambient-write.sh not found"; exit 0; }

# ── Verify the emit block exists in bot-merge.sh (scanner-anchor check) ───────
if grep -q 'bot_merge_rebase_before_test' "$BM"; then
    ok "Scan: bot_merge_rebase_before_test emit present in bot-merge.sh"
else
    fail "Scan: bot_merge_rebase_before_test emit missing from bot-merge.sh"
fi

if grep -q 'bot_merge_test_failure' "$BM"; then
    ok "Scan: bot_merge_test_failure emit present in bot-merge.sh"
else
    fail "Scan: bot_merge_test_failure emit missing from bot-merge.sh"
fi

if grep -qE 'transient_oom|permanent_failure' "$BM"; then
    ok "Scan: failure_class values (transient_oom/permanent_failure) present in bot-merge.sh"
else
    fail "Scan: failure_class values missing from bot-merge.sh"
fi

# ── Extract the rebase-before-test emit block from bot-merge.sh ───────────────
RBT_BLOCK="$(awk '/# ── INFRA-918: emit rebase-before-test ambient signal/,/^}$/' "$BM" | head -20)"
if [[ -n "$RBT_BLOCK" ]]; then
    ok "Scan: INFRA-918 rebase-before-test block extractable from bot-merge.sh"
else
    fail "Scan: could not locate INFRA-918 rebase-before-test block in bot-merge.sh"
fi

# ── Helper: build and run a rebase-before-test driver with given params ────────
run_rbt_driver() {
    local ambient="$1" behind="$2" skip_tests="$3"
    local driver="$TMP/rbt_driver_${behind}_${skip_tests}.sh"
    cat > "$driver" <<DRIVER
#!/usr/bin/env bash
set -uo pipefail
# Stubs
info() { :; }
warn() { :; }

# Load _ambient_write from lib
source "$AMB_WRITE_LIB"

# Globals that the emit block reads
BEHIND=$behind
SKIP_TESTS=$skip_tests
GAP_IDS=("INFRA-TEST-918")
GAP_ID="INFRA-TEST-918"
BRANCH="chump/infra-918-test"
REPO_ROOT="$TMP"
export CHUMP_AMBIENT_LOG="$ambient"

# Stub git rev-parse to return a known SHA
git() {
    if [[ "\${1:-}" == "rev-parse" ]]; then
        echo "deadbeef1234567890abcdef1234567890abcdef"
    fi
}

# Stub cargo check (will_test detection)
cargo() { return 0; }
command() {
    if [[ "\${1:-}" == "-v" && "\${2:-}" == "cargo" ]]; then return 0; fi
    builtin command "\$@"
}

# Execute the emit block extracted from bot-merge.sh
$RBT_BLOCK
DRIVER
    chmod +x "$driver"
    bash "$driver" 2>/dev/null
}

# ── Tests 1-6: bot_merge_rebase_before_test fields ────────────────────────────
AMBIENT1="$TMP/ambient_rbt1.jsonl"
AMBIENT2="$TMP/ambient_rbt2.jsonl"
AMBIENT3="$TMP/ambient_rbt3.jsonl"

echo "--- Tests 1-6: bot_merge_rebase_before_test emission ---"

run_rbt_driver "$AMBIENT1" 0 0   # up-to-date, tests enabled
run_rbt_driver "$AMBIENT2" 3 0   # 3 commits behind, tests enabled
run_rbt_driver "$AMBIENT3" 0 1   # up-to-date, tests disabled

EV1="$(grep '"kind":"bot_merge_rebase_before_test"' "$AMBIENT1" 2>/dev/null | tail -1)"
EV2="$(grep '"kind":"bot_merge_rebase_before_test"' "$AMBIENT2" 2>/dev/null | tail -1)"
EV3="$(grep '"kind":"bot_merge_rebase_before_test"' "$AMBIENT3" 2>/dev/null | tail -1)"

# Test 1: rebased=false when BEHIND=0
if echo "$EV1" | grep -q '"rebased":false'; then
    ok "Test 1: rebased=false when branch is up-to-date"
else
    fail "Test 1: expected rebased=false — event: ${EV1:-<missing>}"
fi

# Test 2: rebased=true when BEHIND > 0
if echo "$EV2" | grep -q '"rebased":true'; then
    ok "Test 2: rebased=true when BEHIND > 0"
else
    fail "Test 2: expected rebased=true — event: ${EV2:-<missing>}"
fi

# Test 3: commits_behind matches BEHIND
if echo "$EV2" | grep -q '"commits_behind":3'; then
    ok "Test 3: commits_behind=3 matches BEHIND variable"
else
    fail "Test 3: expected commits_behind=3 — event: ${EV2:-<missing>}"
fi

# Test 4: head_sha is non-empty
if echo "$EV1" | grep -qE '"head_sha":"[0-9a-f]+"'; then
    ok "Test 4: head_sha is a non-empty hex string"
else
    fail "Test 4: head_sha missing or not hex — event: ${EV1:-<missing>}"
fi

# Test 5: will_test=true when SKIP_TESTS=0
if echo "$EV1" | grep -q '"will_test":true'; then
    ok "Test 5: will_test=true when SKIP_TESTS=0 and cargo available"
else
    fail "Test 5: expected will_test=true — event: ${EV1:-<missing>}"
fi

# Test 6: will_test=false when SKIP_TESTS=1
if echo "$EV3" | grep -q '"will_test":false'; then
    ok "Test 6: will_test=false when SKIP_TESTS=1"
else
    fail "Test 6: expected will_test=false — event: ${EV3:-<missing>}"
fi

# ── Tests 7-8: bot_merge_test_failure classification ──────────────────────────
echo "--- Tests 7-8: bot_merge_test_failure classification ---"

# Extract the classification snippet from bot-merge.sh
CLASSIFY_BLOCK="$(awk '/_bm_tfc_class="permanent_failure"/,/rm -f "\$_bm_test_log"/' "$BM" | head -20)"

run_classify_driver() {
    local ambient="$1" oom_output="$2"
    local log="$TMP/cargo_test_out_${oom_output}.txt"
    if [[ "$oom_output" == "1" ]]; then
        echo "error[E0000]: some error" > "$log"
        echo "signal: 15, SIGTERM: termination signal" >> "$log"
        echo "process didn't exit successfully" >> "$log"
    else
        echo "test foo ... FAILED" > "$log"
        echo "thread 'foo' panicked at 'assertion failed'" >> "$log"
    fi

    local driver="$TMP/classify_driver_${oom_output}.sh"
    cat > "$driver" <<DRIVER
#!/usr/bin/env bash
set -uo pipefail
info() { :; }
red()  { :; }
source "$AMB_WRITE_LIB"
GAP_IDS=("INFRA-TEST-918")
GAP_ID="INFRA-TEST-918"
BRANCH="chump/infra-918-test"
REPO_ROOT="$TMP"
export CHUMP_AMBIENT_LOG="$ambient"
_bm_test_log="$log"
CARGO_BUILD_JOBS=4

$CLASSIFY_BLOCK
DRIVER
    chmod +x "$driver"
    bash "$driver" 2>/dev/null
}

AMBIENT_OOM="$TMP/ambient_oom.jsonl"
AMBIENT_PERM="$TMP/ambient_perm.jsonl"

run_classify_driver "$AMBIENT_OOM" 1
run_classify_driver "$AMBIENT_PERM" 0

EV_OOM="$(grep '"kind":"bot_merge_test_failure"' "$AMBIENT_OOM" 2>/dev/null | tail -1)"
EV_PERM="$(grep '"kind":"bot_merge_test_failure"' "$AMBIENT_PERM" 2>/dev/null | tail -1)"

# Test 7: OOM → transient_oom
if echo "$EV_OOM" | grep -q '"failure_class":"transient_oom"'; then
    ok "Test 7: failure_class=transient_oom on SIGTERM output"
else
    fail "Test 7: expected failure_class=transient_oom — event: ${EV_OOM:-<missing>}"
fi

# Test 8: logic failure → permanent_failure
if echo "$EV_PERM" | grep -q '"failure_class":"permanent_failure"'; then
    ok "Test 8: failure_class=permanent_failure on logic test failure"
else
    fail "Test 8: expected failure_class=permanent_failure — event: ${EV_PERM:-<missing>}"
fi

# ── Test 9: all events are valid JSON ─────────────────────────────────────────
echo "--- Test 9: JSON validity ---"
ALL_EVENTS=("${EV1:-}" "${EV2:-}" "${EV3:-}" "${EV_OOM:-}" "${EV_PERM:-}")
ALL_VALID=1
if command -v python3 &>/dev/null; then
    for ev in "${ALL_EVENTS[@]}"; do
        [[ -z "$ev" ]] && continue
        if ! echo "$ev" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
            ALL_VALID=0
        fi
    done
elif command -v jq &>/dev/null; then
    for ev in "${ALL_EVENTS[@]}"; do
        [[ -z "$ev" ]] && continue
        if ! echo "$ev" | jq . >/dev/null 2>&1; then
            ALL_VALID=0
        fi
    done
fi
if [[ "$ALL_VALID" == "1" ]]; then
    ok "Test 9: all emitted events are valid JSON"
else
    fail "Test 9: one or more events failed JSON parse"
fi

# ── AC #3: verify phase name in bot-merge.sh matches expected string ──────────
echo "--- AC #3: phase label for bot_merge_phase_duration ---"
EXPECTED_PHASE="cargo test --bin chump --tests"
if grep -q "\"${EXPECTED_PHASE}\"" "$BM" 2>/dev/null || \
   grep -q "stage_start \"${EXPECTED_PHASE}\"" "$BM" 2>/dev/null; then
    ok "AC #3: stage_start label '${EXPECTED_PHASE}' present — phase_duration covered by stage_done()"
else
    fail "AC #3: stage_start '${EXPECTED_PHASE}' not found in bot-merge.sh"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
