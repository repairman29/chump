#!/usr/bin/env bash
# test-chump-claim-atomic.sh — INFRA-468
#
# Verifies `chump claim <ID>` does the full 6-step replacement atomically:
# fetch origin, verify gap, doctor probe, derive session ID, create
# worktree, write lease.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHUMP="$REPO_ROOT/target/release/chump"
[[ -x "$CHUMP" ]] || { echo "FATAL: $CHUMP not built"; exit 2; }

echo "=== INFRA-468 chump claim atomic-replacement test ==="
echo

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# --- Build a fake "main" repo with a gap reserved + scripts copied. ---
FAKE="$TMPDIR_BASE/main"
mkdir -p "$FAKE/scripts/coord" "$FAKE/scripts/dev" "$FAKE/scripts/lib" \
         "$FAKE/scripts/git-hooks" "$FAKE/scripts/dispatch" \
         "$FAKE/docs/gaps" "$FAKE/.chump"
git -C "$FAKE" init -q -b main
git -C "$FAKE" config user.email t@t.com
git -C "$FAKE" config user.name t
git -C "$FAKE" config commit.gpgsign false 2>/dev/null || true

# Copy the dependencies the atomic claim needs
cp "$REPO_ROOT/scripts/coord/gap-claim.sh" "$FAKE/scripts/coord/"
cp "$REPO_ROOT/scripts/coord/gap-preflight.sh" "$FAKE/scripts/coord/" 2>/dev/null || true
cp -r "$REPO_ROOT/scripts/lib/." "$FAKE/scripts/lib/"
cp -r "$REPO_ROOT/scripts/git-hooks/." "$FAKE/scripts/git-hooks/" 2>/dev/null || true
cp "$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py" "$FAKE/scripts/dispatch/" 2>/dev/null || true

# Seed a gap via chump gap reserve
git -C "$FAKE" commit --allow-empty -q -m "seed"
# Reserve from inside $FAKE so chump's repo-root resolution lands there
# (not in the test runner's parent worktree — without this, chump's
# `repo_path::repo_root()` resolves to the calling dir's git toplevel and
# we leak TEST-* into the parent worktree's docs/gaps/).
RESERVE_OUT=$(
    cd "$FAKE"
    CHUMP_REPO="$FAKE" "$CHUMP" gap reserve --force --domain TEST --priority P2 \
        --effort xs --title "atomic claim test gap" 2>&1
)
GAP_ID=$(echo "$RESERVE_OUT" | grep -oE 'TEST-[0-9]+' | head -1)
[[ -n "$GAP_ID" ]] || { echo "FATAL: reserve produced no gap ID. Output: $RESERVE_OUT"; exit 2; }

# Need an origin to fetch from — point origin at $FAKE itself (self-remote).
git -C "$FAKE" config receive.denyCurrentBranch ignore
git -C "$FAKE" remote add origin "$FAKE" 2>/dev/null || true
git -C "$FAKE" add docs/.gitkeep 2>/dev/null || mkdir -p "$FAKE/docs" && touch "$FAKE/docs/.gitkeep" && git -C "$FAKE" add "$FAKE/docs/.gitkeep"
git -C "$FAKE" add . >/dev/null
git -C "$FAKE" commit -q -m "seed gap" --no-verify || true

# --- Test 1: chump claim creates worktree + lease atomically ---
WT_BASE="$TMPDIR_BASE/worktrees"
mkdir -p "$WT_BASE"

# Run from inside the fake repo. --skip-doctor (no chump-binary-unwedge.sh in fake)
# and --skip-import (gap is already in DB) keep this hermetic.
CLAIM_OUT=$(
    cd "$FAKE"
    CHUMP_REPO="$FAKE" CHUMP_WORKTREE_BASE="$WT_BASE" \
        "$CHUMP" claim "$GAP_ID" --paths "src/" --skip-doctor --skip-import 2>&1
) || CLAIM_RC=$?
CLAIM_RC="${CLAIM_RC:-0}"

if [[ "$CLAIM_RC" -eq 0 ]]; then
    ok "chump claim $GAP_ID exited 0"
else
    fail "chump claim exited $CLAIM_RC. Output:"
    echo "$CLAIM_OUT" | sed 's/^/    /'
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

# --- Test 2: worktree was created at the expected path ---
GAP_LOWER=$(echo "$GAP_ID" | tr '[:upper:]' '[:lower:]')
EXPECTED_WT="$WT_BASE/chump-${GAP_LOWER}"
if [[ -d "$EXPECTED_WT" ]]; then
    ok "worktree created at $EXPECTED_WT"
else
    fail "expected worktree at $EXPECTED_WT not found"
fi

# --- Test 3: branch was created and checked out in the worktree ---
EXPECTED_BRANCH="chump/${GAP_LOWER}-claim"
if git -C "$EXPECTED_WT" rev-parse --abbrev-ref HEAD 2>/dev/null | grep -qF "$EXPECTED_BRANCH"; then
    ok "worktree on branch $EXPECTED_BRANCH"
else
    actual=$(git -C "$EXPECTED_WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    fail "expected branch $EXPECTED_BRANCH, got $actual"
fi

# --- Test 4: lease file written ---
LEASE_FILES=$(ls "$FAKE/.chump-locks/"*.json 2>/dev/null | grep -v '\.wt-session-id' || true)
if [[ -n "$LEASE_FILES" ]]; then
    LEASE_JSON=$(grep -l "\"gap_id\":[[:space:]]*\"$GAP_ID\"" $LEASE_FILES 2>/dev/null | head -1)
    if [[ -n "$LEASE_JSON" ]]; then
        ok "lease file written for $GAP_ID at $(basename "$LEASE_JSON")"
        # Verify session ID has the claim- prefix (from atomic_claim::derive_session_id)
        if grep -qE '"session_id":[[:space:]]*"claim-' "$LEASE_JSON"; then
            ok "lease has claim-prefixed session ID (distinguishes from fleet/operator)"
        else
            sid=$(grep '"session_id":' "$LEASE_JSON" | head -1)
            fail "session ID missing claim- prefix: $sid"
        fi
    else
        fail "no lease file mentions $GAP_ID. Files found:"
        echo "$LEASE_FILES" | sed 's/^/      /'
    fi
else
    fail "no lease files found in $FAKE/.chump-locks/"
fi

# --- Test 5: claim output includes the cd hint ---
if echo "$CLAIM_OUT" | grep -qF "cd $EXPECTED_WT"; then
    ok "output includes 'cd <worktree>' hint"
else
    fail "output missing 'cd' hint:"
    echo "$CLAIM_OUT" | sed 's/^/      /'
fi

# --- Test 6: claiming the same gap twice fails (worktree already exists) ---
SECOND_RC=0
SECOND_OUT=$(
    cd "$FAKE"
    CHUMP_REPO="$FAKE" CHUMP_WORKTREE_BASE="$WT_BASE" \
        "$CHUMP" claim "$GAP_ID" --skip-doctor --skip-import 2>&1
) || SECOND_RC=$?

if [[ "$SECOND_RC" -ne 0 ]] && echo "$SECOND_OUT" | grep -qF "already exists"; then
    ok "second claim refuses with 'worktree already exists' (no clobber)"
else
    fail "second claim should have rejected; rc=$SECOND_RC, output:"
    echo "$SECOND_OUT" | sed 's/^/      /'
fi

# --- Test 7: missing gap rejected with actionable error ---
THIRD_RC=0
THIRD_OUT=$(
    cd "$FAKE"
    CHUMP_REPO="$FAKE" CHUMP_WORKTREE_BASE="$WT_BASE" \
        "$CHUMP" claim "TEST-9999" --skip-doctor 2>&1
) || THIRD_RC=$?

if [[ "$THIRD_RC" -ne 0 ]] && echo "$THIRD_OUT" | grep -q "not found"; then
    ok "missing gap rejected with 'not found' message"
else
    fail "missing gap should have rejected with not-found; rc=$THIRD_RC"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
