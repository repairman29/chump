#!/usr/bin/env bash
# test-arm-auto-merge.sh — CI smoke test for INFRA-1438
# Rust-First-Bypass: shell test for shell-only feature (verify_arm post-arm check in
#   scripts/coord/auto-merge-armer.sh); no state mutation beyond temp files; < 80 LOC.
#
# Scenarios tested:
#   1. SUCCESS:       gh returns auto_merge=non-null on first check   → exits 0, emits auto_merge_arm_verified
#   2. FAIL:          gh returns null on both checks (GraphQL exhausted) → exits 1, emits auto_merge_arm_verify_failed
#   3. RETRY-SUCCESS: gh returns null first, non-null on retry          → exits 0, emits auto_merge_arm_verified(attempt_count=2)
#
# Stubs: chump_gh (controls auto_merge field), sleep (no-op to keep test fast).
# Never touches real state.db, real GitHub, or real ambient.jsonl.
set -euo pipefail

TMPDIR_TEST="$(mktemp -d)"

# W-013 immunization (RESILIENT-024): unset workflow-injected env so this
# tests own $TMP fixtures are not hijacked by CI workflow CHUMP_LOCK_DIR.
unset CHUMP_REPO CHUMP_LOCK_DIR
trap 'rm -rf "$TMPDIR_TEST"' EXIT

LOCKS_DIR="$TMPDIR_TEST/locks"
AMBIENT_LOG="$LOCKS_DIR/ambient.jsonl"
mkdir -p "$LOCKS_DIR"

# Variables required by verify_arm's command substitution (stubs ignore args).
REPO="test-owner/test-repo"

PASS=0; FAIL=0; declare -a FAILURES=()
pass() { echo "  ✓ $1"; PASS=$(( PASS + 1 )); }
fail() { echo "  ✗ $1"; FAIL=$(( FAIL + 1 )); FAILURES+=("$1"); }

# ── Stubs ─────────────────────────────────────────────────────────────────────

# Override sleep: verify_arm sleeps 2s then 30s — skip in CI.
sleep() { :; }

# emit_ambient: write event JSON to test ambient log (mirrors armer's real impl).
emit_ambient() {
    local kind="$1" pr_num="$2" detail="${3:-}"
    printf '{"kind":"%s","pr":%s,"detail":"%s"}\n' "$kind" "$pr_num" "$detail" \
        >> "$AMBIENT_LOG"
}

# verify_arm — inlined from scripts/coord/auto-merge-armer.sh (INFRA-1438).
# Uses chump_gh stub (below) to control whether auto_merge is null or non-null.
verify_arm() {
    local pr_num="$1" attempt_count="${2:-1}"
    local armed

    sleep 2
    armed="$(chump_gh api "repos/${REPO}/pulls/${pr_num}" \
        --jq '.auto_merge != null' 2>/dev/null || echo 'false')"

    if [[ "${armed}" == "true" ]]; then
        emit_ambient "auto_merge_arm_verified" "${pr_num}" \
            "attempt_count=${attempt_count} script=auto-merge-armer.sh"
        return 0
    fi

    local retry_count=$(( attempt_count + 1 ))
    sleep 30

    armed="$(chump_gh api "repos/${REPO}/pulls/${pr_num}" \
        --jq '.auto_merge != null' 2>/dev/null || echo 'false')"

    if [[ "${armed}" == "true" ]]; then
        emit_ambient "auto_merge_arm_verified" "${pr_num}" \
            "attempt_count=${retry_count} script=auto-merge-armer.sh"
        return 0
    fi

    emit_ambient "auto_merge_arm_verify_failed" "${pr_num}" \
        "attempt_count=${retry_count} script=auto-merge-armer.sh"
    return 1
}

# ── Scenario 1: SUCCESS on first check ────────────────────────────────────────
echo "Scenario 1: auto_merge non-null on first check"
> "$AMBIENT_LOG"
chump_gh() { echo "true"; }

if verify_arm 42 2>/dev/null; then
    pass "verify_arm exits 0 when auto_merge non-null"
else
    fail "verify_arm should exit 0 when auto_merge non-null"
fi
grep -q '"kind":"auto_merge_arm_verified"' "$AMBIENT_LOG" \
    && pass "emits auto_merge_arm_verified" \
    || fail "missing auto_merge_arm_verified event"
! grep -q '"kind":"auto_merge_arm_verify_failed"' "$AMBIENT_LOG" \
    && pass "no spurious auto_merge_arm_verify_failed" \
    || fail "spurious auto_merge_arm_verify_failed on success path"

# ── Scenario 2: FAILURE — null on both checks (GraphQL exhaustion) ────────────
echo "Scenario 2: auto_merge null on both checks (simulates GraphQL exhaustion)"
> "$AMBIENT_LOG"
chump_gh() { echo "false"; }

if ! verify_arm 99 2>/dev/null; then
    pass "verify_arm exits 1 when auto_merge always null"
else
    fail "verify_arm should exit 1 when auto_merge always null"
fi
grep -q '"kind":"auto_merge_arm_verify_failed"' "$AMBIENT_LOG" \
    && pass "emits auto_merge_arm_verify_failed" \
    || fail "missing auto_merge_arm_verify_failed event"
! grep -q '"kind":"auto_merge_arm_verified"' "$AMBIENT_LOG" \
    && pass "no spurious auto_merge_arm_verified on failure path" \
    || fail "spurious auto_merge_arm_verified on failure path"

# ── Scenario 3: RETRY SUCCESS — null on first, non-null on retry ──────────────
echo "Scenario 3: null on first check, non-null on retry"
> "$AMBIENT_LOG"
# Use a file counter because chump_gh runs in a command-substitution subshell;
# parent-shell variable increments do not propagate back.
_CALL_CTR="$TMPDIR_TEST/call_count"
echo 0 > "$_CALL_CTR"
chump_gh() {
    local n; n=$(cat "$_CALL_CTR"); n=$(( n + 1 )); echo "$n" > "$_CALL_CTR"
    [[ $n -eq 1 ]] && echo "false" || echo "true"
}

if verify_arm 7 2>/dev/null; then
    pass "verify_arm exits 0 when retry succeeds"
else
    fail "verify_arm should exit 0 when retry succeeds"
fi
grep -q '"kind":"auto_merge_arm_verified"' "$AMBIENT_LOG" \
    && pass "emits auto_merge_arm_verified on retry" \
    || fail "missing auto_merge_arm_verified on retry"
retry_detail="$(grep '"kind":"auto_merge_arm_verified"' "$AMBIENT_LOG" \
    | grep -o 'attempt_count=[0-9]*' | head -1)"
[[ "$retry_detail" == "attempt_count=2" ]] \
    && pass "verified event carries attempt_count=2 (confirms retry path)" \
    || fail "expected attempt_count=2, got: ${retry_detail:-<empty>}"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    printf '  FAIL: %s\n' "${FAILURES[@]}"
    exit 1
fi
echo "PASS"
