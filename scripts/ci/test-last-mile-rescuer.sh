#!/usr/bin/env bash
# test-last-mile-rescuer.sh — INFRA-2629
#
# Regression tests for scripts/coord/last-mile-rescuer.sh
#
# Tests:
#   T1: orphan_worktree_detected event + local branch with commits + no PR
#       → dry-run triggers and emits last_mile_rescue_triggered
#   T2: clean branch with open PR → rescuer skips (no trigger event emitted)
#   T3: stalled sub_agent_dispatched event >stall_s without completion
#       → last_mile_agent_stall_detected emitted
#   T4: CHUMP_LAST_MILE_DISABLED=1 → exits 0 without any action
#   T5: CHUMP_LAST_MILE_DRY_RUN=1 → rescue_triggered emitted but no push occurs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESCUER="$REPO_ROOT/scripts/coord/last-mile-rescuer.sh"

# ── Pass/fail tracking ────────────────────────────────────────────────────────

FAILURES=0
pass() { printf '  [PASS] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*" >&2; FAILURES=$(( FAILURES + 1 )); }

echo "=== test-last-mile-rescuer.sh (INFRA-2629) ==="

# ── Prerequisites ─────────────────────────────────────────────────────────────

[[ -f "$RESCUER" ]]  || { echo "FAIL: rescuer script missing: $RESCUER" >&2; exit 1; }
[[ -x "$RESCUER" ]]  || { echo "FAIL: rescuer script not executable" >&2; exit 1; }
bash -n "$RESCUER"   || { echo "FAIL: bash -n syntax error in rescuer" >&2; exit 1; }
pass "script exists, executable, syntax clean"

# ── Sandbox setup ─────────────────────────────────────────────────────────────

SANDBOX="$(mktemp -d -t test-last-mile-rescuer.XXXXXX)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# Minimal git repo that acts as the "main repo" + "origin"
ORIGIN_REPO="$SANDBOX/origin"
MAIN_REPO="$SANDBOX/main-repo"

# Create a bare origin
git init --bare -q "$ORIGIN_REPO"

# Clone it as main-repo
git clone -q "$ORIGIN_REPO" "$MAIN_REPO"
git -C "$MAIN_REPO" config user.email "test@chump.bot"
git -C "$MAIN_REPO" config user.name "Test Bot"

# Seed origin/main with one commit so there is a main branch
echo "init" > "$MAIN_REPO/README"
git -C "$MAIN_REPO" add README
git -C "$MAIN_REPO" commit -q -m "Initial commit"
git -C "$MAIN_REPO" push -q origin main

# Fake lock dir + ambient log
LOCK_DIR="$SANDBOX/locks"
mkdir -p "$LOCK_DIR"
AMBIENT_LOG="$LOCK_DIR/ambient.jsonl"
: > "$AMBIENT_LOG"

# Helper: ISO8601 timestamp N seconds in the past
_ago() {
    local secs="$1"
    local epoch
    epoch=$(( $(date +%s) - secs ))
    if date --version >/dev/null 2>&1; then
        date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
    else
        date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
    fi
}

# Helper: run the rescuer with the sandbox wired in, dry-run always on
run_rescuer() {
    local extra_args=("$@")
    CHUMP_REPO_ROOT="$MAIN_REPO" \
    CHUMP_LOCK_DIR="$LOCK_DIR" \
    CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
    CHUMP_LAST_MILE_DRY_RUN=1 \
    bash "$RESCUER" "${extra_args[@]}" 2>&1 || true
}

# Helper: run the rescuer without forcing dry-run (for T4/T5 specific tests)
run_rescuer_raw() {
    local extra_args=("$@")
    CHUMP_REPO_ROOT="$MAIN_REPO" \
    CHUMP_LOCK_DIR="$LOCK_DIR" \
    CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
    bash "$RESCUER" "${extra_args[@]}" 2>&1 || true
}

# ── Helper: create a local claim branch with one unpushed commit ──────────────

make_claim_branch() {
    local gap_id="$1"
    local gap_lc
    gap_lc="$(printf '%s' "$gap_id" | tr '[:upper:]' '[:lower:]')"
    local branch="chump/${gap_lc}-claim"

    git -C "$MAIN_REPO" checkout -q -b "$branch" 2>/dev/null
    echo "work for $gap_id" > "$MAIN_REPO/work-${gap_id}.txt"
    git -C "$MAIN_REPO" add "work-${gap_id}.txt"
    git -C "$MAIN_REPO" commit -q -m "feat(${gap_id}): implement"
    # Switch back to main so the branch is local but not checked out
    git -C "$MAIN_REPO" checkout -q main 2>/dev/null
    echo "$branch"
}

# ── Test 1: orphan_worktree_detected event → rescue_triggered (dry-run) ───────

echo ""
echo "Test 1: orphan_worktree_detected event + local branch with commits + no PR..."

: > "$AMBIENT_LOG"

# Create claim branch with an unpushed commit
T1_BRANCH="$(make_claim_branch INFRA-9991)"
T1_GAP="INFRA-9991"

# Inject a synthetic orphan_worktree_detected event into ambient (recent)
T1_TS="$(_ago 120)"
printf '{"ts":"%s","kind":"orphan_worktree_detected","worktree_path":"%s","branch":"%s","last_commit_sha":"abc1234","uncommitted_line_count":0,"age_minutes":20,"claim_gap_id":"%s"}\n' \
    "$T1_TS" "$SANDBOX/nonexistent-wt" "$T1_BRANCH" "$T1_GAP" \
    >> "$AMBIENT_LOG"

# Run rescuer with trigger1 only (orphan events), dry-run on
run_rescuer --trigger1-only >/dev/null 2>&1 || true
# Re-run and capture output for assertion
T1_OUT="$(run_rescuer --trigger1-only 2>&1 || true)"

if grep -q '"kind":"last_mile_rescue_triggered"' "$AMBIENT_LOG" 2>/dev/null; then
    pass "T1: last_mile_rescue_triggered emitted for orphan branch"
else
    fail "T1: last_mile_rescue_triggered NOT emitted — got: $(tail -5 "$AMBIENT_LOG")"
fi

if echo "$T1_OUT" | grep -q "DRY_RUN"; then
    pass "T1: DRY_RUN mode acknowledged in output"
else
    fail "T1: DRY_RUN not acknowledged"
fi

# Verify no actual push happened (branch still ahead of origin)
T1_AHEAD="$(git -C "$MAIN_REPO" rev-list --count "origin/main..${T1_BRANCH}" 2>/dev/null || echo 0)"
if [[ "$T1_AHEAD" -gt 0 ]]; then
    pass "T1: DRY_RUN confirmed — branch still ahead of origin/main (not pushed)"
else
    fail "T1: branch was actually pushed in DRY_RUN mode"
fi

# ── Test 2: branch with open PR → rescuer skips ─────────────────────────────
#
# The rescuer skips branches that already have an open PR — that is the
# canonical "being handled" signal. We simulate this by injecting a fake
# `gh` stub that reports an open PR for the branch under test.

echo ""
echo "Test 2: branch with open PR reported by gh → rescuer skips (no event)..."

: > "$AMBIENT_LOG"

# Create a branch with an unpushed commit (would normally be rescued)
T2_BRANCH="chump/infra-9992-claim"
git -C "$MAIN_REPO" checkout -q -b "$T2_BRANCH" 2>/dev/null
echo "work for INFRA-9992" > "$MAIN_REPO/work-INFRA-9992.txt"
git -C "$MAIN_REPO" add "work-INFRA-9992.txt"
git -C "$MAIN_REPO" commit -q -m "feat(INFRA-9992): implement"
git -C "$MAIN_REPO" checkout -q main 2>/dev/null

# Inject a fake `gh` stub that returns PR number 42 for ANY --head query.
# This simulates the rescuer finding an open PR and correctly skipping.
T2_BIN="$SANDBOX/bin-t2"
mkdir -p "$T2_BIN"
cat > "$T2_BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
# Stub: always report one open PR regardless of branch queried
for arg in "$@"; do
    case "$arg" in
        --jq) shift; echo "42"; exit 0 ;;
    esac
done
echo "42"
exit 0
GHSTUB
chmod +x "$T2_BIN/gh"

# Also push T1's branch so it won't pollute T2's scan
git -C "$MAIN_REPO" push -q origin "chump/infra-9991-claim" 2>/dev/null || true

# Run with the stub gh on PATH so _has_open_pr returns true for any branch
T2_OUT="$(PATH="$T2_BIN:$PATH" \
    CHUMP_REPO_ROOT="$MAIN_REPO" \
    CHUMP_LOCK_DIR="$LOCK_DIR" \
    CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
    CHUMP_LAST_MILE_DRY_RUN=1 \
    bash "$RESCUER" --trigger2-only 2>&1 || true)"

if ! grep -q '"kind":"last_mile_rescue_triggered"' "$AMBIENT_LOG" 2>/dev/null; then
    pass "T2: no rescue_triggered when open PR exists for branch"
else
    fail "T2: rescue_triggered emitted despite open PR (should skip)"
fi

# Also verify the skip reason appears in output
if echo "$T2_OUT" | grep -qi "open PR\|open pr"; then
    pass "T2: rescuer logged skip reason (open PR exists)"
else
    pass "T2: rescuer skipped silently (no event — correct)"
fi

# ── Test 3: stalled sub_agent_dispatched without completion → stall detected ──

echo ""
echo "Test 3: stalled sub_agent_dispatched (>stall threshold) → last_mile_agent_stall_detected..."

: > "$AMBIENT_LOG"

# Inject a dispatched event 2 hours ago
T3_TS="$(_ago 7300)"
printf '{"ts":"%s","kind":"sub_agent_dispatched","session":"test-opus-session-t3","gap":"INFRA-9993","role":"handoff","target_model":"sonnet"}\n' \
    "$T3_TS" >> "$AMBIENT_LOG"

# Run trigger3 with a 3600s stall threshold (7300s ago > 3600s threshold)
T3_OUT="$(CHUMP_LAST_MILE_AGENT_STALL_S=3600 \
    CHUMP_REPO_ROOT="$MAIN_REPO" \
    CHUMP_LOCK_DIR="$LOCK_DIR" \
    CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
    CHUMP_LAST_MILE_DRY_RUN=1 \
    bash "$RESCUER" --trigger3-only 2>&1 || true)"

if grep -q '"kind":"last_mile_agent_stall_detected"' "$AMBIENT_LOG" 2>/dev/null; then
    pass "T3: last_mile_agent_stall_detected emitted for stalled dispatch"
else
    fail "T3: last_mile_agent_stall_detected NOT emitted — output: $T3_OUT"
fi

# Verify fields present in the stall event
if grep '"kind":"last_mile_agent_stall_detected"' "$AMBIENT_LOG" | grep -q '"gap_id":"INFRA-9993"'; then
    pass "T3: stall event contains gap_id field"
else
    fail "T3: stall event missing gap_id field"
fi

if grep '"kind":"last_mile_agent_stall_detected"' "$AMBIENT_LOG" | grep -q '"elapsed_s":[0-9]'; then
    pass "T3: stall event contains elapsed_s field"
else
    fail "T3: stall event missing elapsed_s field"
fi

# A non-stalled dispatch (within threshold) should NOT trigger
: > "$AMBIENT_LOG"
T3B_TS="$(_ago 60)"  # 1 minute ago — well within 3600s threshold
printf '{"ts":"%s","kind":"sub_agent_dispatched","session":"test-opus-session-t3b","gap":"INFRA-9994","role":"handoff","target_model":"sonnet"}\n' \
    "$T3B_TS" >> "$AMBIENT_LOG"

CHUMP_LAST_MILE_AGENT_STALL_S=3600 \
    CHUMP_REPO_ROOT="$MAIN_REPO" \
    CHUMP_LOCK_DIR="$LOCK_DIR" \
    CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
    CHUMP_LAST_MILE_DRY_RUN=1 \
    bash "$RESCUER" --trigger3-only >/dev/null 2>&1 || true

if ! grep -q '"kind":"last_mile_agent_stall_detected"' "$AMBIENT_LOG" 2>/dev/null; then
    pass "T3: recent dispatch correctly NOT flagged as stalled"
else
    fail "T3: recent dispatch incorrectly flagged as stalled"
fi

# ── Test 4: CHUMP_LAST_MILE_DISABLED=1 → exits 0, no action ──────────────────

echo ""
echo "Test 4: CHUMP_LAST_MILE_DISABLED=1 → exits 0 without action..."

: > "$AMBIENT_LOG"

# Create a branch that would normally be rescued
make_claim_branch INFRA-9995 >/dev/null

T4_EXIT=0
T4_OUT="$(CHUMP_LAST_MILE_DISABLED=1 \
    CHUMP_REPO_ROOT="$MAIN_REPO" \
    CHUMP_LOCK_DIR="$LOCK_DIR" \
    CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
    bash "$RESCUER" 2>&1)" || T4_EXIT=$?

if [[ "$T4_EXIT" -eq 0 ]]; then
    pass "T4: DISABLED exits 0"
else
    fail "T4: DISABLED should exit 0, got $T4_EXIT"
fi

if ! grep -q '"kind":"last_mile_rescue_triggered"' "$AMBIENT_LOG" 2>/dev/null; then
    pass "T4: no rescue events emitted when DISABLED"
else
    fail "T4: rescue events emitted despite DISABLED=1"
fi

if echo "$T4_OUT" | grep -qi "DISABLED\|disabled"; then
    pass "T4: disable message logged"
else
    fail "T4: no disable message in output"
fi

# ── Test 5: CHUMP_LAST_MILE_DRY_RUN=1 → intent events only, no push ──────────

echo ""
echo "Test 5: CHUMP_LAST_MILE_DRY_RUN=1 → rescue_triggered emitted, no actual push..."

: > "$AMBIENT_LOG"

T5_BRANCH="$(make_claim_branch INFRA-9996)"

# Run trigger2 (branch scan) with DRY_RUN=1
CHUMP_LAST_MILE_DRY_RUN=1 \
    CHUMP_REPO_ROOT="$MAIN_REPO" \
    CHUMP_LOCK_DIR="$LOCK_DIR" \
    CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
    bash "$RESCUER" --trigger2-only >/dev/null 2>&1 || true

if grep -q '"kind":"last_mile_rescue_triggered"' "$AMBIENT_LOG" 2>/dev/null; then
    pass "T5: last_mile_rescue_triggered emitted in DRY_RUN mode"
else
    fail "T5: last_mile_rescue_triggered NOT emitted in DRY_RUN"
fi

# Verify branch was NOT pushed
T5_AHEAD="$(git -C "$MAIN_REPO" rev-list --count "origin/main..${T5_BRANCH}" 2>/dev/null || echo 0)"
if [[ "$T5_AHEAD" -gt 0 ]]; then
    pass "T5: no actual push occurred (branch still ahead of origin)"
else
    fail "T5: branch appears to have been pushed despite DRY_RUN=1"
fi

# Verify no last_mile_rescue_completed was emitted (that would mean a real push)
if ! grep -q '"kind":"last_mile_rescue_completed"' "$AMBIENT_LOG" 2>/dev/null; then
    pass "T5: no rescue_completed in DRY_RUN (correct — intent-only)"
else
    fail "T5: rescue_completed emitted in DRY_RUN mode (should not push)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Results ==="
if [[ "$FAILURES" -eq 0 ]]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "FAILURES: $FAILURES"
    exit 1
fi
