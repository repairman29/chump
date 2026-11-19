#!/usr/bin/env bash
# scripts/ci/test-force-push-intent.sh — INFRA-1971
#
# Tests for force-push intent signal (H2 high fix):
#   1. Structural: helper script exists + is executable
#   2. Structural: pr-auto-rearm.sh references the intent file path pattern
#   3. Behavioral: write intent file → mock gh → assert deferred event fires
#   4. Behavioral: bypass env disables intent check
#   5. Behavioral: expired intent file (old mtime) does NOT defer

set -uo pipefail

PASS=0
FAIL=0

ok()   { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== test-force-push-intent.sh ==="

# ── Test 1: helper script exists and is executable ───────────────────────────
echo "--- 1. Structural: helper script exists + executable"
HELPER="$REPO_ROOT/scripts/dev/force-push-intent.sh"
if [[ -f "$HELPER" ]]; then
    ok "force-push-intent.sh exists"
else
    fail "force-push-intent.sh missing at $HELPER"
fi

if [[ -x "$HELPER" ]]; then
    ok "force-push-intent.sh is executable"
else
    fail "force-push-intent.sh is not executable (run: chmod +x $HELPER)"
fi

# ── Test 2: pr-auto-rearm.sh references intent file path pattern ─────────────
echo "--- 2. Structural: pr-auto-rearm.sh references force-push-intent file"
REARM="$REPO_ROOT/scripts/coord/pr-auto-rearm.sh"
if [[ -f "$REARM" ]]; then
    ok "pr-auto-rearm.sh exists"
else
    fail "pr-auto-rearm.sh missing at $REARM"
fi

if grep -q "force-push-intent-" "$REARM" 2>/dev/null; then
    ok "pr-auto-rearm.sh references force-push-intent- file pattern"
else
    fail "pr-auto-rearm.sh does not reference force-push-intent- file pattern"
fi

if grep -q "CHUMP_PR_AUTO_REARM_NO_INTENT_CHECK" "$REARM" 2>/dev/null; then
    ok "pr-auto-rearm.sh has CHUMP_PR_AUTO_REARM_NO_INTENT_CHECK bypass"
else
    fail "pr-auto-rearm.sh missing CHUMP_PR_AUTO_REARM_NO_INTENT_CHECK bypass"
fi

if grep -q "pr_auto_rearm_deferred_for_force_push_intent" "$REARM" 2>/dev/null; then
    ok "pr-auto-rearm.sh emits pr_auto_rearm_deferred_for_force_push_intent event"
else
    fail "pr-auto-rearm.sh missing pr_auto_rearm_deferred_for_force_push_intent emit"
fi

# ── Test 3: behavioral — intent file present → deferred event fires ──────────
echo "--- 3. Behavioral: intent file present → daemon defers + emits event"

TMPDIR_TEST="$(mktemp -d)"
# REARM_LOCKS is where pr-auto-rearm.sh will look (derived from git rev-parse in worktree)
REARM_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REARM_LOCKS="$REARM_ROOT/.chump-locks"
mkdir -p "$REARM_LOCKS"

# Dedicated ambient + state files for this test run (avoid polluting real fleet logs)
MOCK_AMBIENT="$TMPDIR_TEST/ambient-test3.jsonl"
MOCK_STATE="$REARM_LOCKS/pr-auto-rearm-state-test.jsonl"
touch "$MOCK_AMBIENT" "$MOCK_STATE"

# Cleanup: remove test intent files and state on exit
BRANCH_SAFE="chump_test-branch"
INTENT_FILE="$REARM_LOCKS/force-push-intent-${BRANCH_SAFE}.json"
trap 'rm -f "$INTENT_FILE" "$MOCK_STATE" "$REARM_LOCKS/force-push-intent-chump_expired-branch.json"; rm -rf "$TMPDIR_TEST"' EXIT

# Write a fresh intent file for branch "chump/test-branch" into the real locks dir
printf '{"operator_id":"test","ts":"%s","branch":"chump/test-branch","ttl_secs":60}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$INTENT_FILE"

# Create a minimal mock 'gh' that returns a single BLOCKED+disarmed PR on branch chump/test-branch
MOCK_BIN="$TMPDIR_TEST/bin"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/gh" << 'MOCKGH'
#!/usr/bin/env bash
# Mock gh: pr list returns one BLOCKED+disarmed PR; pr view returns branch name
if [[ "$1 $2" == "pr list" ]]; then
    echo '[{"number":9999,"mergeStateStatus":"BLOCKED","autoMergeRequest":null}]'
elif [[ "$1 $2" == "pr view" ]]; then
    echo "chump/test-branch"
fi
MOCKGH
chmod +x "$MOCK_BIN/gh"

# Run pr-auto-rearm.sh with mock environment; fresh STATE avoids throttle collision
MOCK_STATE3="$TMPDIR_TEST/state-test3.jsonl"
touch "$MOCK_STATE3"
output="$(PATH="$MOCK_BIN:$PATH" \
    CHUMP_AMBIENT_LOG="$MOCK_AMBIENT" \
    CHUMP_PR_AUTO_REARM_STATE="$MOCK_STATE3" \
    CHUMP_PR_AUTO_REARM_THROTTLE_MIN="30" \
    CHUMP_PR_AUTO_REARM_INTENT_TTL_SECS="60" \
    bash "$REARM" 2>&1 || true)"

if echo "$output" | grep -q "DEFER #9999"; then
    ok "daemon deferred PR #9999 due to active intent"
else
    fail "daemon did NOT defer PR #9999 — output: $output"
fi

if grep -q "pr_auto_rearm_deferred_for_force_push_intent" "$MOCK_AMBIENT" 2>/dev/null; then
    ok "deferred event written to ambient.jsonl"
else
    fail "no deferred event in ambient.jsonl — content: $(cat "$MOCK_AMBIENT" 2>/dev/null)"
fi

if grep -q '"pr":9999' "$MOCK_AMBIENT" 2>/dev/null; then
    ok "deferred event includes pr:9999"
else
    fail "deferred event missing pr field"
fi

if grep -q '"branch":"chump/test-branch"' "$MOCK_AMBIENT" 2>/dev/null; then
    ok "deferred event includes branch field"
else
    fail "deferred event missing branch field"
fi

# ── Test 4: bypass env disables intent check ─────────────────────────────────
echo "--- 4. Behavioral: CHUMP_PR_AUTO_REARM_NO_INTENT_CHECK=1 bypasses deferral"

MOCK_AMBIENT2="$TMPDIR_TEST/ambient2.jsonl"
touch "$MOCK_AMBIENT2"
# Intent file still present from Test 3

MOCK_STATE4="$TMPDIR_TEST/state-test4.jsonl"
touch "$MOCK_STATE4"
output2="$(PATH="$MOCK_BIN:$PATH" \
    CHUMP_AMBIENT_LOG="$MOCK_AMBIENT2" \
    CHUMP_PR_AUTO_REARM_STATE="$MOCK_STATE4" \
    CHUMP_PR_AUTO_REARM_THROTTLE_MIN="30" \
    CHUMP_PR_AUTO_REARM_NO_INTENT_CHECK="1" \
    bash "$REARM" 2>&1 || true)"

if echo "$output2" | grep -q "DEFER #9999"; then
    fail "bypass env ignored — daemon still deferred"
else
    ok "bypass env respected — no deferral"
fi

if grep -q "pr_auto_rearm_deferred_for_force_push_intent" "$MOCK_AMBIENT2" 2>/dev/null; then
    fail "deferred event should NOT appear when bypass active"
else
    ok "no deferred event emitted when bypass active"
fi

# ── Test 5: expired intent file does NOT defer ───────────────────────────────
echo "--- 5. Behavioral: expired intent file (old mtime) does not defer"

MOCK_AMBIENT3="$TMPDIR_TEST/ambient3.jsonl"
touch "$MOCK_AMBIENT3"

# Create intent file then backdate its mtime by 120s (older than 60s TTL)
# branch_safe for "chump/expired-branch" = "chump_expired-branch"
EXPIRED_BRANCH_SAFE="chump_expired-branch"
INTENT_FILE2="$REARM_LOCKS/force-push-intent-${EXPIRED_BRANCH_SAFE}.json"
printf '{"operator_id":"test","ts":"2000-01-01T00:00:00Z","branch":"chump/expired-branch","ttl_secs":60}\n' \
    > "$INTENT_FILE2"
# Backdate mtime 120 seconds
touch -t "$(date -v-120S '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '120 seconds ago' '+%Y%m%d%H%M.%S' 2>/dev/null || echo '200001010000.00')" \
    "$INTENT_FILE2" 2>/dev/null || true

# Mock gh returning PR on the expired branch
cat > "$MOCK_BIN/gh" << 'MOCKGH2'
#!/usr/bin/env bash
if [[ "$1 $2" == "pr list" ]]; then
    echo '[{"number":8888,"mergeStateStatus":"BLOCKED","autoMergeRequest":null}]'
elif [[ "$1 $2" == "pr view" ]]; then
    echo "chump/expired-branch"
fi
MOCKGH2
chmod +x "$MOCK_BIN/gh"

MOCK_STATE5="$TMPDIR_TEST/state-test5.jsonl"
touch "$MOCK_STATE5"
output3="$(PATH="$MOCK_BIN:$PATH" \
    CHUMP_AMBIENT_LOG="$MOCK_AMBIENT3" \
    CHUMP_PR_AUTO_REARM_STATE="$MOCK_STATE5" \
    CHUMP_PR_AUTO_REARM_THROTTLE_MIN="30" \
    CHUMP_PR_AUTO_REARM_INTENT_TTL_SECS="60" \
    bash "$REARM" 2>&1 || true)"

if echo "$output3" | grep -q "DEFER #8888"; then
    fail "expired intent file still caused deferral — mtime backdating may have failed on this platform"
else
    ok "expired intent file correctly ignored (no deferral)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
