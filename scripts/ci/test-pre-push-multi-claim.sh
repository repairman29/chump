#!/usr/bin/env bash
# test-pre-push-multi-claim.sh — INFRA-2446 regression test.
#
# Verifies the RESILIENT-026 claim-file selection fix:
# when multiple claim-*.json files are present, the pre-push hook must
# match the one whose gap_id matches the current branch — NOT the first
# alphabetically (the pre-INFRA-2446 bug).
#
# 4 cases:
#   1. 3 claim files (A/B/C); current branch = chump/infra-b-claim
#      → validates B's lease, NOT A's (alphabetically first). PASS
#   2. Same 3 files; CHUMP_SESSION_ID matches A's session_id
#      → branch-match still wins over session_id match. PASS
#   3. branch = chump/infra-x-claim, leases for A/B only (no X)
#      → emits prepush_lease_mismatch, exits 0 (no block). PASS
#   4. Single claim file, branch matches → standard validation. PASS

set -euo pipefail

# Use the script's own location to find the repo root — robust against being
# invoked from a different working directory (e.g. main worktree vs infra-2446
# linked worktree). BASH_SOURCE[0] always resolves to this script's path.
REAL_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAL_HOOK="$REAL_REPO_ROOT/scripts/git-hooks/pre-push"

[[ -x "$REAL_HOOK" ]] || { echo "[FAIL] pre-push hook not found / not executable"; exit 1; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# ── Build a self-contained git repo with the hook installed ──────────────────
# The hook computes: REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# So placing the hook at $CLONE/scripts/git-hooks/pre-push makes REPO_ROOT=$CLONE,
# which means git -C "$REPO_ROOT" resolves to the clone (a real git repo) and
# .chump-locks/ (for mock claim files) lives at $CLONE/.chump-locks/.

mkdir -p "$TMP/origin.git"
git init --bare -q "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/clone"
cd "$TMP/clone"
git config user.email "t@t"
git config user.name "t"
echo "init" > README.md
git add README.md
git commit -qm "init"
git push -q origin HEAD:main

# Install the hook inside the clone so REPO_ROOT resolves to clone root.
mkdir -p "$TMP/clone/scripts/git-hooks"
cp "$REAL_HOOK" "$TMP/clone/scripts/git-hooks/pre-push"
chmod +x "$TMP/clone/scripts/git-hooks/pre-push"

# Copy companion scripts the hook may call.
for _companion in pre-push-bypass-trailers.sh; do
    _src="$REAL_REPO_ROOT/scripts/git-hooks/$_companion"
    [[ -f "$_src" ]] && cp "$_src" "$TMP/clone/scripts/git-hooks/" && \
        chmod +x "$TMP/clone/scripts/git-hooks/$_companion"
done

HOOK="$TMP/clone/scripts/git-hooks/pre-push"
LOCKS_DIR="$TMP/clone/.chump-locks"
mkdir -p "$LOCKS_DIR"

# Create the feature branch used by most tests.
cd "$TMP/clone"
git checkout -qb chump/infra-b-claim
echo "work" > work.txt
git add work.txt
git commit -qm "feat(INFRA-B): work"
LOCAL_SHA_B="$(git rev-parse HEAD)"
REMOTE_SHA="$(git rev-parse origin/main)"

# ── Stub gh so Guard 2 (auto-merge armed check) is skipped ───────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# No auto-merge → Guard 2 fast-paths out without blocking.
if [[ "$*" == *"--json"* ]]; then
    echo '{"state":"CLOSED","autoMergeRequest":null,"mergeStateStatus":"UNKNOWN"}'
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"

# ── Helper: write a minimal claim JSON ───────────────────────────────────────
write_claim() {
    local name="$1" gap_id="$2" session_id="$3"
    printf '{"session_id":"%s","gap_id":"%s","taken_at":"2026-06-03T00:00:00Z","expires_at":"2026-06-03T04:00:00Z"}\n' \
        "$session_id" "$gap_id" > "$LOCKS_DIR/$name"
}

# ── Helper: run the hook with all non-RESILIENT-026 guards disabled ───────────
# $1 = branch name, $2 = SHA to present as local, $3 (optional) = extra KEY=VAL
run_hook() {
    local branch="$1" sha="$2" extra="${3:-}"
    local input="refs/heads/${branch} ${sha} refs/heads/${branch} ${REMOTE_SHA}"
    env PATH="$TMP/bin:/usr/bin:/bin:/usr/local/bin" \
        CHUMP_PREFLIGHT_SKIP=1 \
        CHUMP_CI_REGRESSION_GUARD=0 \
        CHUMP_REBASE_DETECT=0 \
        CHUMP_GAP_CHECK=0 \
        CHUMP_BYPASS_TRAILER_CHECK=0 \
        CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl" \
        bash -c "
            ${extra:+export $extra}
            cd '$TMP/clone'
            echo '$input' | PATH='$TMP/bin:/usr/bin:/bin:/usr/local/bin' bash '$HOOK' '$TMP/origin.git' '$TMP/origin.git'
        " 2>&1
}

# ── Test 1: 3 claim files (A/B/C); branch matches B — must validate B ─────────
echo "Test 1: 3 claim files A/B/C; branch=chump/infra-b-claim → must accept (not block on A)"
# Alphabetically: claim-infra-a-*.json sorts before claim-infra-b-*.json.
# Pre-INFRA-2446 bug: head -1 picks A → blocks because branch ≠ chump/infra-a-claim.
write_claim "claim-infra-a-77001-1.json" "INFRA-A" "claim-infra-a-session"
write_claim "claim-infra-b-77002-2.json" "INFRA-B" "claim-infra-b-session"
write_claim "claim-infra-c-77003-3.json" "INFRA-C" "claim-infra-c-session"

set +e
out=$(run_hook "chump/infra-b-claim" "$LOCAL_SHA_B")
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    echo "[FAIL] expected exit 0 (branch matches B's lease), got $rc"
    printf '%s\n' "$out"
    exit 1
fi
if printf '%s\n' "$out" | grep -q "BLOCKED (RESILIENT-026)"; then
    echo "[FAIL] hook blocked despite branch correctly matching B's claim file"
    printf '%s\n' "$out"
    exit 1
fi
echo "[PASS]"

# ── Test 2: CHUMP_SESSION_ID matches A, but branch=chump/infra-b-claim ────────
echo ""
echo "Test 2: CHUMP_SESSION_ID=A's session, branch=chump/infra-b-claim → branch wins"
set +e
out=$(run_hook "chump/infra-b-claim" "$LOCAL_SHA_B" "CHUMP_SESSION_ID=claim-infra-a-session")
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    echo "[FAIL] expected exit 0 (branch-match takes precedence over session_id), got $rc"
    printf '%s\n' "$out"
    exit 1
fi
if printf '%s\n' "$out" | grep -q "BLOCKED (RESILIENT-026)"; then
    echo "[FAIL] session_id match for A wrongly caused block on B's branch"
    printf '%s\n' "$out"
    exit 1
fi
echo "[PASS]"

rm -f "$LOCKS_DIR"/claim-infra-*.json

# ── Test 3: branch=chump/infra-x-claim, leases for A+B only → warn + proceed ──
echo ""
echo "Test 3: branch=chump/infra-x-claim, leases A+B present (no X) → warn + proceed"
write_claim "claim-infra-a-77001-1.json" "INFRA-A" "claim-infra-a-session"
write_claim "claim-infra-b-77002-2.json" "INFRA-B" "claim-infra-b-session"

# Create the X branch in the clone
cd "$TMP/clone"
git checkout -q "chump/infra-b-claim"
git checkout -qb "chump/infra-x-claim"
LOCAL_SHA_X="$(git rev-parse HEAD)"

rm -f "$TMP/ambient.jsonl"   # fresh log so we can check the emit

set +e
out=$(run_hook "chump/infra-x-claim" "$LOCAL_SHA_X")
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    echo "[FAIL] expected exit 0 (no matching lease → proceed without block), got $rc"
    printf '%s\n' "$out"
    exit 1
fi
if printf '%s\n' "$out" | grep -q "BLOCKED (RESILIENT-026)"; then
    echo "[FAIL] hook blocked despite having no matching claim — should warn+proceed"
    printf '%s\n' "$out"
    exit 1
fi
if ! printf '%s\n' "$out" | grep -q "WARN (RESILIENT-026)"; then
    echo "[FAIL] expected 'WARN (RESILIENT-026)' diagnostic for no-match case"
    printf '%s\n' "$out"
    exit 1
fi
if [[ -f "$TMP/ambient.jsonl" ]] && grep -q '"kind":"prepush_lease_mismatch"' "$TMP/ambient.jsonl"; then
    echo "[PASS] (prepush_lease_mismatch emitted to ambient)"
else
    echo "[FAIL] expected prepush_lease_mismatch event in ambient log"
    cat "$TMP/ambient.jsonl" 2>/dev/null || echo "(no ambient log found)"
    exit 1
fi
echo "[PASS]"

rm -f "$LOCKS_DIR"/claim-infra-*.json

# ── Test 4: single claim file, matching branch → standard pass ────────────────
echo ""
echo "Test 4: single claim file B; branch=chump/infra-b-claim → standard validate (pass)"
cd "$TMP/clone"
git checkout -q "chump/infra-b-claim"
LOCAL_SHA_B2="$(git rev-parse HEAD)"
write_claim "claim-infra-b-77002-2.json" "INFRA-B" "claim-infra-b-session"

set +e
out=$(run_hook "chump/infra-b-claim" "$LOCAL_SHA_B2")
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    echo "[FAIL] expected exit 0 (single matching claim), got $rc"
    printf '%s\n' "$out"
    exit 1
fi
if printf '%s\n' "$out" | grep -q "BLOCKED (RESILIENT-026)"; then
    echo "[FAIL] single matching claim incorrectly blocked"
    printf '%s\n' "$out"
    exit 1
fi
echo "[PASS]"

echo ""
echo "[OK] all 4 INFRA-2446 multi-claim RESILIENT-026 cases passed"
