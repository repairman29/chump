#!/usr/bin/env bash
# test-orphan-worktree-watchdog.sh — RESILIENT-026
#
# 5 fixture tests for orphan-worktree-watchdog.sh:
#   T1: live process + uncommitted changes → SKIP (still active)
#   T2: dead process + no uncommitted-or-unpushed → SKIP (clean)
#   T3: dead process + uncommitted changes + >15min idle + no-recent-push → DETECT
#   T4: dead process + unpushed commits + >15min idle + no-recent-push → DETECT
#   T5: no claim file + uncommitted (operator manual worktree) → DETECT with claim_gap_id=null

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WATCHDOG="$REPO_ROOT/scripts/coord/orphan-worktree-watchdog.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

FAILURES=0

# ── Prerequisites ─────────────────────────────────────────────────────────────
echo "=== test-orphan-worktree-watchdog.sh (RESILIENT-026) ==="

[[ -f "$WATCHDOG" ]] || { echo "FAIL: watchdog script missing: $WATCHDOG" >&2; exit 1; }
[[ -x "$WATCHDOG" ]] || { echo "FAIL: watchdog script not executable" >&2; exit 1; }
bash -n "$WATCHDOG" || { echo "FAIL: bash -n syntax error" >&2; exit 1; }
pass "script exists, executable, syntax clean"

# ── Sandbox setup ─────────────────────────────────────────────────────────────
SANDBOX="$(mktemp -d -t test-orphan-watchdog.XXXXXX)"
# shellcheck disable=SC2329
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# Build a minimal "source" git repo so we can add linked worktrees.
SRC_REPO="$SANDBOX/source-repo"
mkdir -p "$SRC_REPO"
git -C "$SRC_REPO" init -q
git -C "$SRC_REPO" config user.email "test@chump.bot"
git -C "$SRC_REPO" config user.name "Test Bot"
echo "init" > "$SRC_REPO/README"
git -C "$SRC_REPO" add README
git -C "$SRC_REPO" commit -q -m "Initial commit"

# Fake lock dir + ambient log
FAKE_LOCKS="$SANDBOX/locks"
mkdir -p "$FAKE_LOCKS"
FAKE_AMBIENT="$FAKE_LOCKS/ambient.jsonl"
: > "$FAKE_AMBIENT"

# Scan dir for chump-* worktrees
FAKE_SCAN="$SANDBOX/scan"
mkdir -p "$FAKE_SCAN"

# Helper: create a linked worktree under FAKE_SCAN named chump-<name>
make_worktree() {
    local name="$1"
    local wt_path="$FAKE_SCAN/chump-${name}"
    local branch="chump/${name}"
    git -C "$SRC_REPO" worktree add "$wt_path" -b "$branch" -q 2>/dev/null
    echo "$wt_path"
}

# Helper: make a worktree appear idle (mtime = NOW - N seconds)
backdate_mtime() {
    local wt="$1" age_sec="$2"
    local target_time=$(( $(date +%s) - age_sec ))
    if [[ "$(uname)" == "Darwin" ]]; then
        touch -mt "$(date -r "$target_time" +%Y%m%d%H%M.%S)" "$wt" 2>/dev/null || true
    else
        touch -d "@${target_time}" "$wt" 2>/dev/null || true
    fi
}

# Helper: create a claim file in FAKE_LOCKS for a worktree
make_claim() {
    local gap_id="$1" session_id="$2" branch="$3"
    local gap_slug
    gap_slug="$(printf '%s' "$gap_id" | tr '[:upper:]' '[:lower:]')"
    cat > "$FAKE_LOCKS/claim-${gap_slug}-${session_id}.json" <<EOF
{
    "session_id": "$session_id",
    "gap_id": "$gap_id",
    "purpose": "gap:$gap_id",
    "taken_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

# Run the watchdog in test mode: override scan dir, lock dir, ambient log.
# The watchdog uses REPO_ROOT to call `git worktree list` — we point it at our
# source repo via CHUMP_LOCK_DIR and CHUMP_AMBIENT_LOG, and override the scan
# dir via --worktree-scan-dir. We also need the worktrees to be registered in
# SRC_REPO's worktree list (they are, because we used `git worktree add` on it).
# run_watchdog kept for documentation; tests use run_watchdog_in_repo directly
# shellcheck disable=SC2329
run_watchdog() {
    CHUMP_LOCK_DIR="$FAKE_LOCKS" \
    CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" \
    CHUMP_ORPHAN_IDLE_MIN=15 \
    bash "$WATCHDOG" \
        --worktree-scan-dir "$FAKE_SCAN" \
        --lock-dir "$FAKE_LOCKS" \
        "$@" 2>&1
}

# Override REPO_ROOT inside watchdog via env — the script resolves REPO_ROOT
# from git. We need the watchdog to see SRC_REPO as the repo root so it runs
# `git worktree list` against it. We can do this by setting GIT_DIR.
# shellcheck disable=SC2120
run_watchdog_in_repo() {
    CHUMP_REPO_ROOT="$SRC_REPO" \
    CHUMP_LOCK_DIR="$FAKE_LOCKS" \
    CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" \
    CHUMP_ORPHAN_IDLE_MIN=15 \
    bash "$WATCHDOG" \
        --worktree-scan-dir "$FAKE_SCAN" \
        --lock-dir "$FAKE_LOCKS" \
        "$@" 2>&1
}

# ── T1: live process + uncommitted changes → SKIP ─────────────────────────────
echo "--- T1: live process + uncommitted changes → SKIP ---"
WT1=$(make_worktree "t1-live")
# Add uncommitted change
echo "dirty" > "$WT1/dirty.txt"
git -C "$WT1" add dirty.txt

# Create a claim with the current shell's PID as session_id (live process)
LIVE_SID="test-session-$$"
make_claim "TEST-001" "$LIVE_SID" "chump/t1-live"
# Patch claim file so purpose matches the branch
cat > "$FAKE_LOCKS/claim-test-001-${LIVE_SID}.json" <<EOF
{
    "session_id": "$LIVE_SID",
    "gap_id": "TEST-001",
    "purpose": "gap:TEST-001 chump/t1-live $WT1",
    "taken_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
# Backdate mtime so it appears idle >15min
backdate_mtime "$WT1" 1800

# We need a live process that contains $LIVE_SID in its args.
# Use python3 to run a sleep with the session_id as a visible arg, so pgrep -af finds it.
python3 -c "import time,sys; time.sleep(60)" "$LIVE_SID" &
LIVE_PID=$!
# Disown so bash doesn't report job termination status (set -e safe)
disown "$LIVE_PID" 2>/dev/null || true
trap 'kill $LIVE_PID 2>/dev/null || true; rm -rf "$SANDBOX"' EXIT

: > "$FAKE_AMBIENT"
# shellcheck disable=SC2119
out=$(run_watchdog_in_repo 2>&1 || true)
kill "$LIVE_PID" 2>/dev/null || true

if echo "$out" | grep -q "SKIP.*t1-live\|t1-live.*live_process\|SKIP $WT1"; then
    pass "T1: live process → SKIP (still active)"
elif ! grep -q "orphan_worktree_detected" "$FAKE_AMBIENT"; then
    # Acceptable: no detection event emitted for t1 (it was skipped)
    pass "T1: live process → SKIP (no detect event emitted)"
else
    # If we emitted a detect event for t1, that's a failure
    if grep "orphan_worktree_detected" "$FAKE_AMBIENT" | grep -q "t1-live"; then
        fail "T1: emitted detect event for live-process worktree — should have skipped"
    else
        pass "T1: live process → SKIP (detect events for other worktrees only)"
    fi
fi

# ── T2: dead process + no uncommitted-or-unpushed → SKIP ─────────────────────
echo "--- T2: dead process + clean worktree → SKIP ---"
WT2=$(make_worktree "t2-clean")
# No uncommitted changes, no claim file (so no live process)
backdate_mtime "$WT2" 1800

: > "$FAKE_AMBIENT"
# shellcheck disable=SC2119
out=$(run_watchdog_in_repo 2>&1 || true)
if grep "orphan_worktree_detected" "$FAKE_AMBIENT" | grep -q "t2-clean"; then
    fail "T2: emitted detect event for clean worktree — should have skipped"
else
    pass "T2: clean worktree → SKIP (no detect event)"
fi

# ── T3: dead process + uncommitted changes + >15min idle → DETECT ─────────────
echo "--- T3: dead process + uncommitted + idle >15min → DETECT ---"
WT3=$(make_worktree "t3-uncommitted")
# Add uncommitted change
echo "uncommitted work" > "$WT3/work.txt"
git -C "$WT3" add work.txt
# Claim with a dead session_id (random, no matching process)
DEAD_SID3="dead-session-t3-$(date +%s)"
cat > "$FAKE_LOCKS/claim-test-003-${DEAD_SID3}.json" <<EOF
{
    "session_id": "$DEAD_SID3",
    "gap_id": "TEST-003",
    "purpose": "gap:TEST-003 $WT3",
    "taken_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
backdate_mtime "$WT3" 1800

: > "$FAKE_AMBIENT"
# shellcheck disable=SC2119
run_watchdog_in_repo > /dev/null 2>&1 || true
if grep "orphan_worktree_detected" "$FAKE_AMBIENT" | grep -q "t3-uncommitted"; then
    pass "T3: uncommitted + dead process + idle → DETECT (event emitted)"
else
    fail "T3: expected detect event for t3-uncommitted, none found. ambient: $(cat "$FAKE_AMBIENT")"
fi

# ── T4: dead process + unpushed commits + >15min idle → DETECT ────────────────
echo "--- T4: dead process + unpushed commits + idle >15min → DETECT ---"
WT4=$(make_worktree "t4-unpushed")
# Set up tracking so @{u} resolves to main (via self-remote "."), then commit
# ahead of it. This simulates a worktree whose branch has new unpushed work.
git -C "$SRC_REPO" config "branch.chump/t4-unpushed.remote" "."
git -C "$SRC_REPO" config "branch.chump/t4-unpushed.merge" "refs/heads/main"
# Now commit new work (one commit ahead of main → unpushed)
echo "unpushed work" > "$WT4/feature.txt"
git -C "$WT4" add feature.txt
git -C "$WT4" -c user.email="test@chump.bot" -c user.name="Test" commit -q -m "Unpushed work"
# Claim with dead session
DEAD_SID4="dead-session-t4-$(date +%s)"
cat > "$FAKE_LOCKS/claim-test-004-${DEAD_SID4}.json" <<EOF
{
    "session_id": "$DEAD_SID4",
    "gap_id": "TEST-004",
    "purpose": "gap:TEST-004 $WT4",
    "taken_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
backdate_mtime "$WT4" 1800

: > "$FAKE_AMBIENT"
# shellcheck disable=SC2119
run_watchdog_in_repo > /dev/null 2>&1 || true
if grep "orphan_worktree_detected" "$FAKE_AMBIENT" | grep -q "t4-unpushed"; then
    pass "T4: unpushed commits + dead process + idle → DETECT (event emitted)"
else
    fail "T4: expected detect event for t4-unpushed, none found. ambient: $(cat "$FAKE_AMBIENT")"
fi

# ── T5: no claim file + uncommitted (manual operator worktree) → DETECT null gap ──
echo "--- T5: no claim file + uncommitted → DETECT with claim_gap_id=null ---"
WT5=$(make_worktree "t5-noclaim")
# Add uncommitted change, no claim file
echo "manual work" > "$WT5/manual.txt"
git -C "$WT5" add manual.txt
backdate_mtime "$WT5" 1800

: > "$FAKE_AMBIENT"
# shellcheck disable=SC2119
run_watchdog_in_repo > /dev/null 2>&1 || true
if grep "orphan_worktree_detected" "$FAKE_AMBIENT" | grep -q "t5-noclaim"; then
    if grep "orphan_worktree_detected" "$FAKE_AMBIENT" | grep "t5-noclaim" | grep -q '"claim_gap_id":null'; then
        pass "T5: no claim file → DETECT with claim_gap_id=null"
    else
        fail "T5: detect event emitted but claim_gap_id is not null. event: $(grep t5-noclaim "$FAKE_AMBIENT")"
    fi
else
    fail "T5: expected detect event for t5-noclaim, none found. ambient: $(cat "$FAKE_AMBIENT")"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ $FAILURES -eq 0 ]]; then
    echo "=== ALL 5 TESTS PASSED ==="
    exit 0
else
    echo "=== $FAILURES TEST(S) FAILED ===" >&2
    exit 1
fi
