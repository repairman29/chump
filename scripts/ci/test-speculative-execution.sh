#!/usr/bin/env bash
# test-speculative-execution.sh — INFRA-193
#
# Verifies the opt-in speculative-execution coordination contract:
#   1. gap-claim.sh --speculative writes `"speculative": true` into the lease
#   2. Two speculative claims for the same gap_id co-exist (preflight allows)
#   3. A non-speculative claim still loses to an existing claim (default safety)
#   4. A speculative claimer is blocked by an existing NON-speculative claim
#      (other side opted out — exclusive semantics still respected)
#
# Sandbox approach: override CHUMP_LOCK_DIR to a tmp dir so we don't touch
# the real .chump-locks/ tree. Skip the path-case + main-worktree + ambient
# guards via env. Each "session" is just a different CHUMP_SESSION_ID.
#
# Run: bash scripts/ci/test-speculative-execution.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLAIM_SH="$REPO_ROOT/scripts/coord/gap-claim.sh"
PREFLIGHT_SH="$REPO_ROOT/scripts/coord/gap-preflight.sh"

[[ -x "$CLAIM_SH" ]]     || { echo "[FAIL] $CLAIM_SH missing"; exit 1; }
[[ -x "$PREFLIGHT_SH" ]] || { echo "[FAIL] $PREFLIGHT_SH missing"; exit 1; }

SANDBOX="$(mktemp -d)"
LOCK_DIR="$SANDBOX/locks"
mkdir -p "$LOCK_DIR"
trap 'rm -rf "$SANDBOX"' EXIT

# Common env for all gap-claim / gap-preflight invocations:
#   - CHUMP_LOCK_DIR sandbox
#   - bypass path-case, main-worktree, ambient, hooks, NATS, broadcast
#   - test gap ID
GAP="SPECTEST-001"
common_env=(
    env
    CHUMP_LOCK_DIR="$LOCK_DIR"
    CHUMP_PATH_CASE_CHECK=0
    CHUMP_ALLOW_MAIN_WORKTREE=1
    CHUMP_AMBIENT_GLANCE=0
    CHUMP_AMBIENT_SESSION_START_EMIT=0
    PATH="$REPO_ROOT/.skip-coord-bin:$PATH"  # ensure no chump-coord on PATH
)

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# Block real broadcast.sh / install-hooks.sh from running by emptying PATH-
# hits via stubbing — simplest: invoke with explicit override that disables
# the optional paths inside gap-claim.sh. The script already guards each
# optional helper with `-x` checks, but broadcast.sh + install-hooks.sh exist
# in the tree. Override with no-op shims via a tmp PATH prefix.
mkdir -p "$SANDBOX/binstubs"
cat > "$SANDBOX/binstubs/git" <<'EOF'
#!/usr/bin/env bash
# Forward to real git, but answer worktree queries from the sandbox.
real_git=$(command -v -p git 2>/dev/null || echo /usr/bin/git)
"$real_git" "$@"
EOF
chmod +x "$SANDBOX/binstubs/git"

# Helper to silence the broadcast/install-hooks side effects via env bypass.
# gap-claim.sh checks `-x` on those paths but always runs git/realpath etc.
# We swap REPO_ROOT so the optional helpers don't exist (no-op).
fake_repo_for_gapclaim() {
    # Make a tiny "repo" — gap-claim.sh runs `git rev-parse --show-toplevel`
    # from PWD. Init a tmp git repo so REPO_ROOT resolves cleanly without
    # the optional helper paths under it.
    local d="$1"
    mkdir -p "$d"
    (cd "$d" && git init --quiet && git config user.email t@t && git config user.name t)
    # Add a single-commit so HEAD exists and worktree-list returns the path.
    (cd "$d" && touch .keep && git add .keep && git commit --quiet -m init >/dev/null)
}

WORK1="$SANDBOX/wt1"
WORK2="$SANDBOX/wt2"
WORK3="$SANDBOX/wt3"
fake_repo_for_gapclaim "$WORK1"
fake_repo_for_gapclaim "$WORK2"
fake_repo_for_gapclaim "$WORK3"

# Each fake worktree gets the SAME shared LOCK_DIR via env so the leases
# collide as they would in the real .chump-locks/ tree.
SESS_A="spec-test-A"
SESS_B="spec-test-B"
SESS_C="spec-test-C"

echo "=== INFRA-193 speculative-execution coordination tests ==="
echo

# ───────────────────────────────────────────────────────────────────────────
# Test 1: --speculative writes "speculative": true into the lease
# ───────────────────────────────────────────────────────────────────────────
( cd "$WORK1" && CHUMP_SESSION_ID="$SESS_A" "${common_env[@]}" \
    bash "$CLAIM_SH" "$GAP" --speculative >/dev/null 2>&1 )

LEASE_A="$LOCK_DIR/${SESS_A}.json"
if [[ -f "$LEASE_A" ]] && python3 -c "import json,sys; sys.exit(0 if json.load(open('$LEASE_A')).get('speculative') is True else 1)"; then
    pass "Test 1: --speculative writes speculative=true into lease"
else
    fail "Test 1: lease did not contain speculative=true ($LEASE_A)"
    [[ -f "$LEASE_A" ]] && cat "$LEASE_A"
fi

# ───────────────────────────────────────────────────────────────────────────
# Test 2: a SECOND speculative claim co-exists with the first (preflight passes)
# ───────────────────────────────────────────────────────────────────────────
set +e
( cd "$WORK2" && CHUMP_SESSION_ID="$SESS_B" CHUMP_SPECULATIVE=1 "${common_env[@]}" \
    bash "$PREFLIGHT_SH" "$GAP" 2>/tmp/spec-test-pf2.err )
PF2_RC=$?
set -e

if [[ $PF2_RC -eq 0 ]] && grep -q "INFRA-193 speculative race" /tmp/spec-test-pf2.err; then
    pass "Test 2: speculative claimer #2 passes preflight when sibling is also speculative"
else
    fail "Test 2: preflight rc=$PF2_RC for spec-on-spec (expected 0 + race notice)"
    cat /tmp/spec-test-pf2.err
fi

# Now actually write claim B and confirm both leases co-exist
( cd "$WORK2" && CHUMP_SESSION_ID="$SESS_B" "${common_env[@]}" \
    bash "$CLAIM_SH" "$GAP" --speculative >/dev/null 2>&1 )

LEASE_B="$LOCK_DIR/${SESS_B}.json"
if [[ -f "$LEASE_A" ]] && [[ -f "$LEASE_B" ]] \
    && python3 -c "import json; a=json.load(open('$LEASE_A')); b=json.load(open('$LEASE_B')); assert a['gap_id']=='$GAP' and b['gap_id']=='$GAP' and a['speculative'] and b['speculative']"; then
    pass "Test 2b: both speculative leases present and active for same gap"
else
    fail "Test 2b: leases not both present/speculative"
fi

# ───────────────────────────────────────────────────────────────────────────
# Test 3: a NON-speculative claim is blocked by the existing speculative one
# (default safety: opting out of the race forfeits the right to race)
# ───────────────────────────────────────────────────────────────────────────
set +e
( cd "$WORK3" && CHUMP_SESSION_ID="$SESS_C" "${common_env[@]}" \
    bash "$PREFLIGHT_SH" "$GAP" 2>/tmp/spec-test-pf3.err )
PF3_RC=$?
set -e

if [[ $PF3_RC -ne 0 ]]; then
    pass "Test 3: non-speculative claimer is blocked by existing speculative claim"
else
    fail "Test 3: non-speculative claimer was NOT blocked (rc=$PF3_RC); preflight stderr:"
    cat /tmp/spec-test-pf3.err
fi

# ───────────────────────────────────────────────────────────────────────────
# Test 4: a SPECULATIVE claim is blocked by an existing NON-speculative claim
# (other side never opted in — exclusive semantics respected)
# ───────────────────────────────────────────────────────────────────────────
# Reset to a fresh gap and lock dir for this test.
GAP2="SPECTEST-002"
SESS_D="spec-test-D"   # owns the non-speculative claim
SESS_E="spec-test-E"   # tries to race

# D writes a normal (non-speculative) claim
( cd "$WORK1" && CHUMP_SESSION_ID="$SESS_D" "${common_env[@]}" \
    bash "$CLAIM_SH" "$GAP2" >/dev/null 2>&1 )

# E tries to claim with --speculative; preflight should still REFUSE
set +e
( cd "$WORK2" && CHUMP_SESSION_ID="$SESS_E" CHUMP_SPECULATIVE=1 "${common_env[@]}" \
    bash "$PREFLIGHT_SH" "$GAP2" 2>/tmp/spec-test-pf4.err )
PF4_RC=$?
set -e

if [[ $PF4_RC -ne 0 ]]; then
    pass "Test 4: speculative claimer is blocked when existing claim is NOT speculative"
else
    fail "Test 4: speculative claimer was NOT blocked by exclusive existing claim (rc=$PF4_RC)"
    cat /tmp/spec-test-pf4.err
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $FAIL
