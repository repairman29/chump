#!/usr/bin/env bash
# test-preflight-pr-check.sh — Check 1.5 coverage: block when open PR implements gap
# Acceptance: scripts/ci/test-preflight-pr-check.sh asserts both branches (INFRA-273)
#
# Verifies:
#   (1) Check 1.5 blocks when an open PR title matches the gap-ID
#   (2) CHUMP_PREFLIGHT_PR_CHECK=0 bypasses the block
#   (3) CHUMP_SPECULATIVE=1 bypasses the block (INFRA-193 race mode)
#   (4) No matching open PR → gap passes preflight normally
#   (5) Own-branch PR (same headRefName as current HEAD) → not blocked
#
# Run:
#   ./scripts/ci/test-preflight-pr-check.sh
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); FAILS+=("$*"); }

echo "=== INFRA-273 gap-preflight Check 1.5 unit tests ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT_REAL="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREFLIGHT="$REPO_ROOT_REAL/scripts/coord/gap-preflight.sh"

if [[ ! -x "$PREFLIGHT" ]]; then
    echo "FATAL: gap-preflight.sh not executable: $PREFLIGHT"
    exit 2
fi

# Minimal GAPS_YAML content that makes Check 1 pass for INFRA-FAKE.
# gap-preflight.sh checks: GAPS_YAML="${GAPS_YAML:-$GAPS_YAML_REMOTE}"
# By pre-setting GAPS_YAML in the environment, we bypass the git-fetch / local-read
# path and hand the script a registry where INFRA-FAKE is open.
# Format matches what _load_gaps_yaml_from_ref produces (post-INFRA-188 monolithic style).
FAKE_GAPS_YAML="$(cat <<'YAML'
gaps:
- id: INFRA-FAKE
  status: open
YAML
)"

# ── Stub factories ────────────────────────────────────────────────────────────

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

make_fake_repo() {
    local name="$1"
    local dir="$TMPDIR_BASE/$name"
    mkdir -p "$dir/.chump-locks"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    echo "$dir"
}

# Stub: gh returns a JSON object matching the gap-ID search (simulates open PR)
make_stub_gh_match() {
    local dir="$1"
    local pr_num="${2:-99}"
    local pr_branch="${3:-chump/some-other-branch}"
    mkdir -p "$dir"
    cat > "$dir/gh" <<STUBEOF
#!/usr/bin/env bash
if [[ "\$*" == *"--search"* && "\$*" == *"in:title"* ]]; then
    echo '{"number":${pr_num},"headRefName":"${pr_branch}"}'
    exit 0
fi
exit 0
STUBEOF
    chmod +x "$dir/gh"
}

# Stub: gh returns no matching PR.
# Real `gh pr list --json ... -q '.[0]'` on an empty result set outputs "null"
# (jq's representation of .[0] on []). gap-preflight.sh guards on != "null", so
# returning "null" (or empty) correctly skips the blocking branch.
make_stub_gh_no_match() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/gh" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"--search"* && "$*" == *"in:title"* ]]; then
    echo 'null'
    exit 0
fi
exit 0
STUBEOF
    chmod +x "$dir/gh"
}

# ── Helper: run preflight with a stub gh binary ───────────────────────────────
# - Pre-sets GAPS_YAML so Check 1 (registry lookup) sees INFRA-FAKE as open.
# - Disables NATS check (no chump-coord in tests).
# - Empty CHUMP_LOCK_DIR so Check 2 (live lease) sees no conflicts.
# - Extra env vars are passed as KEY=VAL strings appended after positional args.
# Captures combined stdout+stderr in global $OUTPUT; sets $RC to exit code.
run_preflight() {
    local stub_dir="$1"
    local repo_dir="$2"
    local gap_id="$3"
    local -a extra=()
    if [[ $# -gt 3 ]]; then
        extra=("${@:4}")
    fi

    set +e
    OUTPUT="$(env \
        PATH="${stub_dir}:${PATH}" \
        GAPS_YAML="$FAKE_GAPS_YAML" \
        REMOTE='' BASE=main \
        CHUMP_LOCK_DIR="$repo_dir/.chump-locks" \
        CHUMP_SESSION_ID="test-session-$$" \
        CHUMP_PREFLIGHT_NATS_CHECK=0 \
        "${extra[@]+"${extra[@]}"}" \
        bash "$PREFLIGHT" "$gap_id" 2>&1 || true)"
    RC=$?
    set -e
}

# ── Test 1: open PR matching the gap-ID → blocked ─────────────────────────────
echo "--- Test 1: blocks when open PR matches gap-ID ---"
T1_REPO="$(make_fake_repo t1)"
T1_STUBS="$TMPDIR_BASE/t1-stubs"
make_stub_gh_match "$T1_STUBS" 99 "chump/some-other-branch"
run_preflight "$T1_STUBS" "$T1_REPO" INFRA-FAKE
if echo "$OUTPUT" | grep -q "SKIP INFRA-FAKE"; then
    ok "Test 1: Check 1.5 blocks when open PR matches gap-ID"
else
    fail "Test 1: Expected 'SKIP INFRA-FAKE' but output was: >>>$OUTPUT<<<"
fi

# ── Test 2: CHUMP_PREFLIGHT_PR_CHECK=0 bypasses the block ─────────────────────
echo "--- Test 2: CHUMP_PREFLIGHT_PR_CHECK=0 bypasses the block ---"
T2_REPO="$(make_fake_repo t2)"
T2_STUBS="$TMPDIR_BASE/t2-stubs"
make_stub_gh_match "$T2_STUBS" 99 "chump/some-other-branch"
run_preflight "$T2_STUBS" "$T2_REPO" INFRA-FAKE "CHUMP_PREFLIGHT_PR_CHECK=0"
if echo "$OUTPUT" | grep -q "OK INFRA-FAKE"; then
    ok "Test 2: CHUMP_PREFLIGHT_PR_CHECK=0 bypasses the block"
else
    fail "Test 2: CHUMP_PREFLIGHT_PR_CHECK=0 should allow claim, but output was: >>>$OUTPUT<<<"
fi

# ── Test 3: CHUMP_SPECULATIVE=1 bypasses the block ────────────────────────────
echo "--- Test 3: CHUMP_SPECULATIVE=1 bypasses the block (INFRA-193 race mode) ---"
T3_REPO="$(make_fake_repo t3)"
T3_STUBS="$TMPDIR_BASE/t3-stubs"
make_stub_gh_match "$T3_STUBS" 99 "chump/some-other-branch"
run_preflight "$T3_STUBS" "$T3_REPO" INFRA-FAKE "CHUMP_SPECULATIVE=1"
if echo "$OUTPUT" | grep -q "OK INFRA-FAKE"; then
    ok "Test 3: CHUMP_SPECULATIVE=1 bypasses the PR block (INFRA-193 race mode)"
else
    fail "Test 3: CHUMP_SPECULATIVE=1 should bypass but output was: >>>$OUTPUT<<<"
fi

# ── Test 4: no matching open PR → gap passes preflight ────────────────────────
echo "--- Test 4: no matching open PR → gap passes preflight ---"
T4_REPO="$(make_fake_repo t4)"
T4_STUBS="$TMPDIR_BASE/t4-stubs"
make_stub_gh_no_match "$T4_STUBS"
run_preflight "$T4_STUBS" "$T4_REPO" INFRA-FAKE
if echo "$OUTPUT" | grep -q "OK INFRA-FAKE"; then
    ok "Test 4: No matching open PR — gap passes preflight normally"
else
    fail "Test 4: No-match case should pass but output was: >>>$OUTPUT<<<"
fi

# ── Test 5: own branch owns the open PR → not blocked ────────────────────────
echo "--- Test 5: own branch owns the open PR → not blocked ---"
T5_REPO="$(make_fake_repo t5)"
T5_STUBS="$TMPDIR_BASE/t5-stubs"
# gap-preflight Check 1.5 calls: git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD
# REPO_ROOT is set by repo-paths.sh from the git context of the worktree that runs the
# preflight. Since we're running under /tmp/infra-273-work, REPO_ROOT will be that path.
# HEAD there is chump/infra-273-fleet-3-20260502-221924. We stub gh to return a PR
# whose headRefName matches that branch → the "own branch" guard fires → not blocked.
CURRENT_WT_HEAD="$(git -C "$REPO_ROOT_REAL" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"
make_stub_gh_match "$T5_STUBS" 77 "$CURRENT_WT_HEAD"
run_preflight "$T5_STUBS" "$T5_REPO" INFRA-FAKE
if echo "$OUTPUT" | grep -q "OK INFRA-FAKE"; then
    ok "Test 5: Own-branch PR (#77, headRefName=$CURRENT_WT_HEAD) → not blocked (same-branch re-run guard)"
else
    fail "Test 5: Own-branch PR should not block but output was: >>>$OUTPUT<<<"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "${#FAILS[@]}" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
