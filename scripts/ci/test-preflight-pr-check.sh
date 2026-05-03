#!/usr/bin/env bash
# test-preflight-pr-check.sh — INFRA-273
#
# Verifies the gap-preflight Check 1.5 contract: block claim when an open PR
# already implements the gap (title contains the gap-ID), with bypass env.
#
# Test coverage:
#   1. Block: gap-preflight.sh exits 1 when open PR with gap-ID in title exists
#   2. Bypass: CHUMP_PREFLIGHT_PR_CHECK=0 skips Check 1.5 and exits 0
#   3. Own-branch: does NOT block when the matching PR is on OUR current branch
#   4. CHUMP_SPECULATIVE=1: allows the race (exits 0 when PR exists)
#   5. No open PRs for gap: exits 0 (normal free-gap path)
#
# Sandbox approach: stub `git` and `gh` via PATH prefix.
#   - The git stub serves the fetch+ls-tree+show trio to inject a minimal
#     GAPS_YAML (one gap, status: open) without touching the real repo.
#   - The gh stub returns canned PR JSON for "pr list" calls.
#   - Both stubs delegate everything else to the real binary.
#
# Run: bash scripts/ci/test-preflight-pr-check.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || realpath "$(dirname "$0")/../..")"
PREFLIGHT_SH="$REPO_ROOT/scripts/coord/gap-preflight.sh"

[[ -x "$PREFLIGHT_SH" ]] || { echo "[FAIL] $PREFLIGHT_SH missing or not executable"; exit 1; }

# ── Sandbox setup ────────────────────────────────────────────────────────────
SANDBOX="$(mktemp -d)"
LOCK_DIR="$SANDBOX/locks"
BINSTUBS="$SANDBOX/binstubs"
FAKE_REPO="$SANDBOX/fake-repo"
mkdir -p "$LOCK_DIR" "$BINSTUBS" "$FAKE_REPO/.git"
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0
pass() { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }

GAP="INFRA-PRCHECK-273"
OTHER_BRANCH="chump/infra-prcheck-273-sibling"
OUR_BRANCH="chump/infra-273-fleet-4-20260502-221923"

# Minimal gap YAML that gap_status() will find.
# The per-file format: each file content is just the gap body (no "gaps:" header).
# gap_status() greps for "^- id: GAP$" in the concatenated output of
# _load_gaps_yaml_local, which prepends "gaps:\n" and each file's content.
MINIMAL_YAML_BODY="- id: ${GAP}
  domain: INFRA
  title: test gap for preflight PR check
  status: open
  priority: P1
  effort: xs"

# git stub: intercepts the calls that gap-preflight.sh uses for YAML loading.
# fetch → exits 0 (success, no output needed)
# ls-tree → returns one synthetic gap file
# show origin/main:docs/gaps/INFRA-PRCHECK-273.yaml → returns minimal YAML body
# rev-parse --show-toplevel → returns FAKE_REPO (the sandbox path)
# rev-parse --git-common-dir → returns ".git" (so MAIN_REPO = FAKE_REPO)
# rev-parse --abbrev-ref HEAD → returns our branch
# Everything else → real git
make_git_stub() {
    local our_branch="$1"
    cat > "$BINSTUBS/git" <<EOFGIT
#!/usr/bin/env bash
# Fake git for gap-preflight sandbox testing (INFRA-273).
case "\$*" in
    *"fetch "*) exit 0 ;;
    *"ls-tree --name-only -r"*"docs/gaps/"*)
        echo "docs/gaps/${GAP}.yaml"
        exit 0
        ;;
    *"show "*"docs/gaps/${GAP}.yaml"*)
        printf '%s\n' "${MINIMAL_YAML_BODY}"
        exit 0
        ;;
    *"show "*"docs/gaps.yaml"*)
        exit 1   # no monolithic file
        ;;
    *"rev-parse --show-toplevel"*)
        echo "${FAKE_REPO}"
        exit 0
        ;;
    *"rev-parse --git-common-dir"*)
        echo ".git"
        exit 0
        ;;
    *"rev-parse --abbrev-ref HEAD"*)
        echo "${our_branch}"
        exit 0
        ;;
esac
_real=\$(PATH="\${PATH#*:}" command -v git 2>/dev/null || echo /usr/bin/git)
exec "\$_real" "\$@"
EOFGIT
    chmod +x "$BINSTUBS/git"
}

# gh stub: returns a controlled single-object JSON for "pr list --state open"
# searches; returns empty for everything else.
# The real "gh pr list ... -q '.[0]'" outputs a single JSON object (or empty).
make_gh_stub() {
    local pr_json="$1"   # single JSON object like {"number":874,"headRefName":"foo"} or ""
    cat > "$BINSTUBS/gh" <<EOFGH
#!/usr/bin/env bash
# Fake gh for gap-preflight sandbox testing (INFRA-273).
if [[ "\$*" == *"pr list"*"--state open"* ]]; then
    # Return the canned response (single object that mimics "gh ... -q '.[0]'").
    printf '%s\n' '${pr_json}'
    exit 0
fi
# For other gh calls (Check 4's file-scope query uses --jq, not -q '.[0]'), return empty.
exit 0
EOFGH
    chmod +x "$BINSTUBS/gh"
}

# Run gap-preflight.sh with sandbox env.
# Extra env vars (if any) are passed as KEY=VALUE args before "--".
# Usage: run_preflight [KEY=VAL ...] -- GAP_ID
run_preflight() {
    local -a extra_env=()
    local gap_id=""
    local sep_seen=0
    for arg in "$@"; do
        if [[ "$arg" == "--" ]]; then sep_seen=1; continue; fi
        if [[ $sep_seen -eq 0 ]]; then extra_env+=("$arg"); else gap_id="$arg"; fi
    done
    env \
        PATH="$BINSTUBS:$PATH" \
        CHUMP_LOCK_DIR="$LOCK_DIR" \
        CHUMP_PREFLIGHT_NATS_CHECK=0 \
        REMOTE=origin \
        BASE=main \
        "${extra_env[@]}" \
        bash "$PREFLIGHT_SH" "$gap_id" 2>&1
}

echo "=== INFRA-273 preflight PR-check tests ==="
echo

# ───────────────────────────────────────────────────────────────────────────
# Test 1: block when open PR with gap-ID in title exists (NOT our branch)
# Expected: exits 1, output mentions "open PR #874"
# ───────────────────────────────────────────────────────────────────────────
make_git_stub "$OUR_BRANCH"
make_gh_stub '{"number":874,"headRefName":"'"$OTHER_BRANCH"'"}'

set +e
out1=$(run_preflight CHUMP_SESSION_ID=sess-test1 -- "$GAP")
rc1=$?
set -e

if [[ $rc1 -ne 0 ]] && echo "$out1" | grep -q "open PR #874"; then
    pass "Test 1: blocks claim when open PR with gap-ID in title exists (different branch)"
else
    fail "Test 1: expected rc!=0 + 'open PR #874'; got rc=$rc1"
    echo "$out1" | head -10
fi

# ───────────────────────────────────────────────────────────────────────────
# Test 2: CHUMP_PREFLIGHT_PR_CHECK=0 bypasses Check 1.5 — exits 0
# Expected: exits 0 (gh is called but block is skipped)
# ───────────────────────────────────────────────────────────────────────────
make_git_stub "$OUR_BRANCH"
make_gh_stub '{"number":874,"headRefName":"'"$OTHER_BRANCH"'"}'

set +e
out2=$(run_preflight CHUMP_SESSION_ID=sess-test2 CHUMP_PREFLIGHT_PR_CHECK=0 -- "$GAP")
rc2=$?
set -e

if [[ $rc2 -eq 0 ]]; then
    pass "Test 2: CHUMP_PREFLIGHT_PR_CHECK=0 bypasses PR-title block"
else
    fail "Test 2: expected rc=0 with CHUMP_PREFLIGHT_PR_CHECK=0; got rc=$rc2"
    echo "$out2" | head -10
fi

# ───────────────────────────────────────────────────────────────────────────
# Test 3: CHUMP_SPECULATIVE=1 bypasses Check 1.5 — exits 0
# Expected: exits 0 (speculative race, no block)
# ───────────────────────────────────────────────────────────────────────────
make_git_stub "$OUR_BRANCH"
make_gh_stub '{"number":874,"headRefName":"'"$OTHER_BRANCH"'"}'

set +e
out3=$(run_preflight CHUMP_SESSION_ID=sess-test3 CHUMP_SPECULATIVE=1 -- "$GAP")
rc3=$?
set -e

if [[ $rc3 -eq 0 ]]; then
    pass "Test 3: CHUMP_SPECULATIVE=1 bypasses PR-title block (speculative race)"
else
    fail "Test 3: expected rc=0 with CHUMP_SPECULATIVE=1; got rc=$rc3"
    echo "$out3" | head -10
fi

# ───────────────────────────────────────────────────────────────────────────
# Test 4: own-branch PR is NOT blocked (re-running preflight on our own work)
# The gh stub returns a PR whose headRefName IS our current branch.
# Expected: exits 0 (own-branch detected, no block)
# ───────────────────────────────────────────────────────────────────────────
make_git_stub "$OUR_BRANCH"
make_gh_stub '{"number":999,"headRefName":"'"$OUR_BRANCH"'"}'

set +e
out4=$(run_preflight CHUMP_SESSION_ID=sess-test4 -- "$GAP")
rc4=$?
set -e

if [[ $rc4 -eq 0 ]]; then
    pass "Test 4: own-branch PR does NOT trigger block (re-run scenario)"
else
    fail "Test 4: expected rc=0 for own-branch PR; got rc=$rc4"
    echo "$out4" | head -10
fi

# ───────────────────────────────────────────────────────────────────────────
# Test 5: no open PRs — exits 0 (normal free-gap path)
# The gh stub returns empty (no open PRs).
# Expected: exits 0
# ───────────────────────────────────────────────────────────────────────────
make_git_stub "$OUR_BRANCH"
make_gh_stub ''

set +e
out5=$(run_preflight CHUMP_SESSION_ID=sess-test5 -- "$GAP")
rc5=$?
set -e

if [[ $rc5 -eq 0 ]]; then
    pass "Test 5: no open PRs for gap → exits 0 (gap is free)"
else
    fail "Test 5: expected rc=0 when no open PRs; got rc=$rc5"
    echo "$out5" | head -10
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
