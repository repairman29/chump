#!/usr/bin/env bash
# test-claim-branch-mismatch.sh — INFRA-1649 (re-do of INFRA-1598) smoke test
# for `chump verify-claim-branch`.
#
# Stages a throwaway git repo + a `.chump-locks/<session>.json` claim lease,
# then exercises the four verdicts:
#   1. no leases at all              -> exit 0
#   2. branch matches claimed gap    -> exit 0
#   3. branch does NOT match claim   -> exit 1 with the named-branch diff
#   4. only a peer session's lease   -> exit 0 (not blocking)
#
# Run from repo root: bash scripts/ci/test-claim-branch-mismatch.sh

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

CHUMP="${REPO_ROOT}/target/debug/chump"
[[ ! -x "$CHUMP" ]] && CHUMP="${HOME}/.cargo/chump-shared-target/debug/chump"
[[ ! -x "$CHUMP" ]] && CHUMP="${HOME}/.cargo/bin/chump"
[[ ! -x "$CHUMP" ]] && CHUMP="$(command -v chump 2>/dev/null || echo "")"

if [[ -z "$CHUMP" || ! -x "$CHUMP" ]]; then
    echo "SKIP: chump binary not found (build with 'cargo build --bin chump' first)"
    exit 0
fi

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

git init -q "$SANDBOX"
git -C "$SANDBOX" config user.email "test@example.com"
git -C "$SANDBOX" config user.name "test"
git -C "$SANDBOX" commit -q --allow-empty -m "init"

run_chump() {
    (cd "$SANDBOX" && CHUMP_REPO="$SANDBOX" CHUMP_SESSION_ID="$1" "$CHUMP" verify-claim-branch --json)
}

# --- Test 1: no leases at all -> exit 0 ------------------------------------
git -C "$SANDBOX" checkout -q -b chump/whatever-branch
rc=0
out=$(run_chump "claim-test-1") || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q '"verdict":"no_leases"' <<<"$out"; then
    pass "no leases -> exit 0"
else
    fail "no leases -> expected exit 0 + verdict=no_leases, got rc=$rc out=$out"
fi

# --- Test 2: branch matches claimed gap -> exit 0 --------------------------
mkdir -p "$SANDBOX/.chump-locks"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_lease() {
    # $1=filename $2=session_id $3=gap_id
    cat > "$SANDBOX/.chump-locks/$1" <<EOF
{"session_id":"$2","paths":[],"taken_at":"$NOW","expires_at":"2099-01-01T00:00:00Z","heartbeat_at":"$NOW","purpose":"test","worktree":"","gap_id":"$3"}
EOF
}
write_lease "claim-infra-1649-claim.json" "claim-infra-1649-claim" "INFRA-1649"
git -C "$SANDBOX" checkout -q -b chump/infra-1649-claim
rc=0
out=$(run_chump "claim-infra-1649-claim") || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q '"verdict":"ok"' <<<"$out"; then
    pass "matching branch -> exit 0"
else
    fail "matching branch -> expected exit 0 + verdict=ok, got rc=$rc out=$out"
fi

# --- Test 3: branch mismatch -> exit 1 with named-branch diff --------------
git -C "$SANDBOX" checkout -q -b chump/wrong-branch-name
rc=0
out=$(run_chump "claim-infra-1649-claim") || rc=$?
if [[ "$rc" -eq 1 ]] \
    && grep -q '"verdict":"mismatch"' <<<"$out" \
    && grep -q '"current_branch":"chump/wrong-branch-name"' <<<"$out" \
    && grep -q '"expected_branch":"chump/infra-1649-claim"' <<<"$out"; then
    pass "branch mismatch -> exit 1 with named-branch diff"
else
    fail "branch mismatch -> expected exit 1 + verdict=mismatch, got rc=$rc out=$out"
fi

# --- Test 4: only a peer session's lease -> exit 0 (not blocking) ----------
rm -f "$SANDBOX/.chump-locks/claim-infra-1649-claim.json"
write_lease "claim-infra-9999-claim.json" "claim-infra-9999-claim" "INFRA-9999"
rc=0
out=$(run_chump "claim-mine-unrelated") || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q '"verdict":"peer_leases_only"' <<<"$out"; then
    pass "peer-only lease -> exit 0, not blocking"
else
    fail "peer-only lease -> expected exit 0 + verdict=peer_leases_only, got rc=$rc out=$out"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
