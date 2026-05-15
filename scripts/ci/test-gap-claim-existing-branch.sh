#!/usr/bin/env bash
# test-gap-claim-existing-branch.sh — INFRA-573: verify gap-claim.sh refuses to
# claim when a matching branch already exists on origin.
#
# Verifies:
#   (1) Existing origin branch → exit 1 with clear error message.
#   (2) No existing origin branch → proceeds past the guard (exit 0 or continues).
#   (3) CHUMP_ALLOW_REUSE_BRANCH=1 → bypasses the guard.
#   (4) Error message includes the bypass hint.

set -euo pipefail

PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GAP_CLAIM="$REPO_ROOT/scripts/coord/gap-claim.sh"
[[ -x "$GAP_CLAIM" ]] || { echo "FATAL: $GAP_CLAIM not executable"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Minimal fake git repo + linked worktree to satisfy main-worktree guard ────
FAKE_REPO="$TMP/repo"
mkdir -p "$FAKE_REPO"
cd "$FAKE_REPO"
git init -q
git commit -q --allow-empty -m "init"
FAKE_WT="$TMP/worktree"
git worktree add -q "$FAKE_WT" -b chump/test-wt HEAD
mkdir -p "$FAKE_WT/.chump-locks"

echo "=== test-gap-claim-existing-branch.sh (INFRA-573) ==="

# Helper: write a git stub that intercepts ls-remote calls.
# $1 = stub bin dir, $2 = branch ref to return (empty = no match)
make_git_stub() {
    local stub_dir="$1"
    local branch_ref="${2:-}"
    local git_real
    git_real="$(command -v git)"
    mkdir -p "$stub_dir"
    # Write the stub; use printf with %b to emit a real tab in the hash line.
    cat >"$stub_dir/git" <<STUB_EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "ls-remote" ]]; then
    if [[ -n "${branch_ref}" ]]; then
        printf 'abc123def456\t%s\n' "${branch_ref}"
    fi
    exit 0
fi
exec "${git_real}" "\$@"
STUB_EOF
    chmod +x "$stub_dir/git"
}

# Common env block for all test invocations (disables guards we're not testing).
run_claim() {
    local stub_dir="$1"; shift
    local gap_id="$1"; shift
    # remaining args are extra env vars (KEY=VAL)
    env \
        PATH="${stub_dir}:${PATH}" \
        CHUMP_ALLOW_MAIN_WORKTREE=0 \
        CHUMP_PATH_CASE_CHECK=0 \
        CHUMP_AMBIENT_GLANCE=0 \
        CHUMP_AMBIENT_SESSION_START_EMIT=0 \
        CHUMP_SESSION_ID="test-session-573" \
        GAP_CLAIM_TTL_HOURS=4 \
        CHUMP_LOCK_DIR="${FAKE_WT}/.chump-locks" \
        "$@" \
        "$GAP_CLAIM" "$gap_id" 2>&1
}

cd "$FAKE_WT"

# ── 1. Existing origin branch → exit 1 with error message ────────────────────
echo "--- Test 1: existing remote branch → exit 1 ---"
STUB1="$TMP/stub1"
make_git_stub "$STUB1" "refs/heads/chump/infra-999-old-session"
set +e
OUT1="$(run_claim "$STUB1" INFRA-999)"
RC1=$?
set -e
if [[ "$RC1" -eq 1 ]]; then
    ok "exit 1 when branch exists on origin"
else
    fail "expected exit 1 when branch exists on origin, got $RC1 (output: $OUT1)"
fi
if printf '%s' "$OUT1" | grep -q "branch already exists on origin"; then
    ok "error message mentions 'branch already exists on origin'"
else
    fail "error message missing 'branch already exists on origin' (got: $OUT1)"
fi
if printf '%s' "$OUT1" | grep -q "chump/infra-999-old-session"; then
    ok "error message includes the branch name"
else
    fail "error message missing branch name (got: $OUT1)"
fi

# ── 2. No existing origin branch → guard passes ───────────────────────────────
echo "--- Test 2: no remote branch → guard passes ---"
STUB2="$TMP/stub2"
make_git_stub "$STUB2" ""
set +e
OUT2="$(run_claim "$STUB2" INFRA-888)"
RC2=$?
set -e
if printf '%s' "$OUT2" | grep -q "branch already exists on origin"; then
    fail "guard triggered unexpectedly with no remote branch (output: $OUT2)"
else
    ok "guard passes when no remote branch exists (rc=$RC2)"
fi

# ── 3. CHUMP_ALLOW_REUSE_BRANCH=1 → bypass ───────────────────────────────────
echo "--- Test 3: CHUMP_ALLOW_REUSE_BRANCH=1 bypasses guard ---"
STUB3="$TMP/stub3"
make_git_stub "$STUB3" "refs/heads/chump/infra-777-old"
set +e
OUT3="$(run_claim "$STUB3" INFRA-777 CHUMP_ALLOW_REUSE_BRANCH=1)"
set -e
if printf '%s' "$OUT3" | grep -q "branch already exists on origin"; then
    fail "CHUMP_ALLOW_REUSE_BRANCH=1 did not bypass the guard (output: $OUT3)"
else
    ok "CHUMP_ALLOW_REUSE_BRANCH=1 bypasses the guard"
fi

# ── 4. Error message includes CHUMP_ALLOW_REUSE_BRANCH=1 bypass hint ─────────
echo "--- Test 4: error message mentions bypass env var ---"
STUB4="$TMP/stub4"
make_git_stub "$STUB4" "refs/heads/chump/infra-555-abandoned"
set +e
OUT4="$(run_claim "$STUB4" INFRA-555)"
set -e
if printf '%s' "$OUT4" | grep -q "CHUMP_ALLOW_REUSE_BRANCH=1"; then
    ok "error message includes CHUMP_ALLOW_REUSE_BRANCH=1 bypass hint"
else
    fail "error message missing bypass hint (got: $OUT4)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    printf '  FAILED: %s\n' "${FAILS[@]}"
    exit 1
fi
exit 0
