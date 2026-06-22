#!/usr/bin/env bash
# scripts/ci/test-bot-merge-rebase-before-test.sh — INFRA-918 contract test
#
# Asserts that bot-merge.sh runs cargo test AFTER git rebase (not before),
# and that the observability events for this guarantee are wired up.
#
# Checks (static analysis only — no git/gh sandbox required):
# 1. Rebase section appears before cargo test section in source order
# 2. kind=bot_merge_rebase_before_test event is emitted before §4
# 3. Event records rebased, commits_behind, head_sha, will_test fields
# 4. kind=bot_merge_test_failure event with failure_class is emitted on failure
# 5. Failure taxonomy distinguishes transient_oom vs permanent_failure
# 6. scanner-anchor comments present for both event kinds
# 7. INFRA-918 reference present
# 8. bash -n syntax check

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

[[ -f "$BOT_MERGE" ]] || { echo "FAIL: bot-merge.sh not found at $BOT_MERGE"; exit 1; }

PASS=0
FAIL=0

assert() {
    local desc="$1" pattern="$2"
    if grep -qE "$pattern" "$BOT_MERGE"; then
        echo "[PASS] $desc"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $desc"
        echo "       expected pattern: $pattern"
        FAIL=$((FAIL + 1))
    fi
}

assert_order() {
    local desc="$1" pattern_before="$2" pattern_after="$3"
    local line_before line_after
    line_before=$(grep -n "$pattern_before" "$BOT_MERGE" 2>/dev/null | head -1 | cut -d: -f1)
    line_after=$(grep -n "$pattern_after" "$BOT_MERGE" 2>/dev/null | head -1 | cut -d: -f1)
    if [[ -n "$line_before" && -n "$line_after" && "$line_before" -lt "$line_after" ]]; then
        echo "[PASS] $desc (line $line_before < $line_after)"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $desc (before=${line_before:-?} after=${line_after:-?})"
        FAIL=$((FAIL + 1))
    fi
}

# ── 1. Ordering: rebase section before cargo test ────────────────────────────
assert_order "rebase section appears before cargo test section" \
    "git rebase" \
    "cargo test --bin chump"

# ── 2. Ordering: bot_merge_rebase_before_test emitted before test stage ──────
assert_order "bot_merge_rebase_before_test emitted before cargo test stage_start" \
    "bot_merge_rebase_before_test" \
    'stage_start "cargo test'

# ── 3. Event fields: rebased, commits_behind, head_sha, will_test ────────────
assert "bot_merge_rebase_before_test includes rebased field" \
    '"rebased"'

assert "bot_merge_rebase_before_test includes will_test field" \
    '"will_test"'

assert "bot_merge_rebase_before_test includes head_sha field" \
    '"head_sha"'

assert "bot_merge_rebase_before_test includes commits_behind field" \
    '"commits_behind"'

# ── 4. Failure taxonomy event ─────────────────────────────────────────────────
assert "bot_merge_test_failure event kind wired" \
    '"kind":"bot_merge_test_failure"'

assert "failure_class field present in test failure event" \
    '"failure_class"'

# ── 5. Failure class values ───────────────────────────────────────────────────
assert "transient_oom class value present" \
    'transient_oom'

assert "permanent_failure class value present" \
    'permanent_failure'

assert "SIGTERM/OOM detection pattern present" \
    'signal: 15|SIGTERM|Killed'

# ── 6. scanner-anchor comments ────────────────────────────────────────────────
assert "scanner-anchor for bot_merge_rebase_before_test present" \
    'scanner-anchor.*bot_merge_rebase_before_test'

assert "scanner-anchor for bot_merge_test_failure present" \
    'scanner-anchor.*bot_merge_test_failure'

# ── 7. INFRA-918 reference ────────────────────────────────────────────────────
assert "INFRA-918 reference present" \
    'INFRA-918'

# ── 8. bash syntax check ─────────────────────────────────────────────────────
if bash -n "$BOT_MERGE" 2>/dev/null; then
    echo "[PASS] bash -n bot-merge.sh — syntax clean"
    PASS=$((PASS + 1))
else
    echo "[FAIL] bash -n bot-merge.sh — syntax error introduced"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"

[[ $FAIL -eq 0 ]] || exit 1
