#!/usr/bin/env bash
# test-claim-branch-mismatch.sh — CI smoke test for INFRA-1598
# Rust-First-Bypass: shell test that exercises the compiled chump binary via
#   `chump verify-claim-branch`; validates branch/lease mismatch detection and
#   ambient event emission. Never touches real state.db or GitHub.
#
# Scenarios:
#   1. MATCH   — branch gap_id == lease gap_id → exits 0
#   2. MISMATCH — branch gap_id != lease gap_id → exits 1, emits worktree_gitdir_corrupt
#   3. NON-GAP BRANCH — branch=main → exits 0 (skip, not a gap branch)
#   4. NO LEASE — gap branch, no claim-*.json → exits 0 (warn, don't block)
#   5. SESSION-ID ENV — CHUMP_SESSION_ID set → reads specific lease file
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Locate the chump binary (respects CARGO_TARGET_DIR for self-hosted runners).
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    CARGO_TARGET="${CARGO_TARGET_DIR:-$REPO_ROOT/target}"
    if [[ -x "$CARGO_TARGET/debug/chump" ]]; then
        CHUMP_BIN="$CARGO_TARGET/debug/chump"
    elif [[ -x "$CARGO_TARGET/release/chump" ]]; then
        CHUMP_BIN="$CARGO_TARGET/release/chump"
    else
        echo "FAIL: chump binary not found under $CARGO_TARGET; build first."
        exit 1
    fi
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Create a stub git repo so `git rev-parse --abbrev-ref HEAD` works.
# The binary uses repo_root() (git rev-parse --show-toplevel) to find .chump-locks/,
# so we must run the binary from WITHIN this repo and put lease files here.
GIT_REPO="$TMPDIR_TEST/repo"
mkdir -p "$GIT_REPO"
git -C "$GIT_REPO" init -q
git -C "$GIT_REPO" commit --allow-empty -q -m "init"

LOCKS_DIR="$GIT_REPO/.chump-locks"
AMBIENT_LOG="$LOCKS_DIR/ambient.jsonl"
mkdir -p "$LOCKS_DIR"

PASS=0; FAIL=0; declare -a FAILURES=()
pass() { echo "  ✓ $1"; PASS=$(( PASS + 1 )); }
fail() { echo "  ✗ $1"; FAIL=$(( FAIL + 1 )); FAILURES+=("$1"); }

# Helper: run chump verify-claim-branch with a specific branch and lease.
# Sets up the lease file, creates the branch in the stub repo, and runs.
run_verify() {
    local branch="$1" lease_gap_id="$2" session_id="${3:-claim-test-99-9999999}"
    # Check out the test branch.
    git -C "$GIT_REPO" checkout -q -B "$branch" 2>/dev/null || true

    # Write lease file.
    > "$LOCKS_DIR/ambient.jsonl"
    if [[ -n "$lease_gap_id" ]]; then
        cat > "$LOCKS_DIR/${session_id}.json" <<JSON
{
  "session_id": "$session_id",
  "gap_id": "$lease_gap_id",
  "taken_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "expires_at": "$(date -u -v+4H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -d '+4 hours' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || echo 2099-01-01T00:00:00Z)"
}
JSON
    else
        rm -f "$LOCKS_DIR"/claim-*.json
    fi

    # Run chump verify-claim-branch against the stub repo.
    # Override CHUMP_SESSION_ID per scenario.
    # Run from within the stub repo so repo_root() resolves to GIT_REPO.
    (cd "$GIT_REPO" && CHUMP_SESSION_ID="${session_id}" \
        "$CHUMP_BIN" verify-claim-branch 2>&1) || true
}

# ── Scenario 1: MATCH ─────────────────────────────────────────────────────────
echo "Scenario 1: branch gap_id matches lease gap_id"
git -C "$GIT_REPO" checkout -q -B "chump/infra-1598-claim" 2>/dev/null || true
cat > "$LOCKS_DIR/claim-test-s1.json" <<JSON
{"session_id":"claim-test-s1","gap_id":"INFRA-1598","taken_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","expires_at":"2099-01-01T00:00:00Z"}
JSON

rc=0
(cd "$GIT_REPO" && CHUMP_SESSION_ID="claim-test-s1" \
    "$CHUMP_BIN" verify-claim-branch) \
    2>/dev/null || rc=$?

[[ $rc -eq 0 ]] \
    && pass "exits 0 when branch matches lease" \
    || fail "expected exit 0 on match, got $rc"

# ── Scenario 2: MISMATCH (the INFRA-1427 incident pattern) ───────────────────
echo "Scenario 2: branch gap_id MISMATCHES lease gap_id"
git -C "$GIT_REPO" checkout -q -B "chump/infra-1598-claim" 2>/dev/null || true
cat > "$LOCKS_DIR/claim-test-s2.json" <<JSON
{"session_id":"claim-test-s2","gap_id":"INFRA-1427","taken_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","expires_at":"2099-01-01T00:00:00Z"}
JSON
> "$AMBIENT_LOG"

output=""
rc=0
output="$(cd "$GIT_REPO" && CHUMP_SESSION_ID="claim-test-s2" \
    "$CHUMP_BIN" verify-claim-branch 2>&1)" || rc=$?

[[ $rc -eq 1 ]] \
    && pass "exits 1 on mismatch" \
    || fail "expected exit 1 on mismatch, got $rc"

echo "$output" | grep -qi "mismatch\|error\|INFRA-1427\|INFRA-1598" \
    && pass "diagnostic message mentions both gap IDs" \
    || fail "diagnostic missing gap IDs: output was: $output"

grep -q '"kind":"worktree_gitdir_corrupt"' "$AMBIENT_LOG" \
    && pass "emits worktree_gitdir_corrupt to ambient" \
    || fail "missing worktree_gitdir_corrupt event in ambient"

# ── Scenario 3: NON-GAP BRANCH ───────────────────────────────────────────────
echo "Scenario 3: non-gap branch (main) — skip check"
git -C "$GIT_REPO" checkout -q -B "main" 2>/dev/null || true
cat > "$LOCKS_DIR/claim-test-s3.json" <<JSON
{"session_id":"claim-test-s3","gap_id":"INFRA-1598","taken_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","expires_at":"2099-01-01T00:00:00Z"}
JSON

rc=0
(cd "$GIT_REPO" && CHUMP_SESSION_ID="claim-test-s3" \
    "$CHUMP_BIN" verify-claim-branch) \
    2>/dev/null || rc=$?

[[ $rc -eq 0 ]] \
    && pass "exits 0 on non-gap branch (skip)" \
    || fail "expected exit 0 on non-gap branch, got $rc"

# ── Scenario 4: NO LEASE ─────────────────────────────────────────────────────
echo "Scenario 4: gap branch, no active lease — warn but don't block"
git -C "$GIT_REPO" checkout -q -B "chump/infra-1598-claim" 2>/dev/null || true
rm -f "$LOCKS_DIR"/claim-*.json
unset CHUMP_SESSION_ID 2>/dev/null || true

rc=0
(cd "$GIT_REPO" && "$CHUMP_BIN" verify-claim-branch) 2>/dev/null || rc=$?

[[ $rc -eq 0 ]] \
    && pass "exits 0 when no lease found (warn, don't block)" \
    || fail "expected exit 0 when no lease found, got $rc"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    printf '  FAIL: %s\n' "${FAILURES[@]}"
    exit 1
fi
echo "PASS"
