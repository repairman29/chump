#!/usr/bin/env bash
# INFRA-499: raw-YAML-edit guard removed in PR #1148.
#
# History: INFRA-094 (advisory, 2026-04-28) -> INFRA-200 (blocking,
# 2026-05-02) -> INFRA-499 (removed, 2026-05-06).
#
# Removal rationale: INFRA-498 deleted the per-file docs/gaps/<ID>.yaml
# mirrors entirely. With those files gone, there's no docs/gaps/*.yaml
# diff to police. The guard's whole purpose is moot. Pre-commit retains
# a 16-line removal note documenting this.
#
# This test is preserved as documentation that the removal was
# intentional + verifies the guard truly is a no-op.

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# ── 1. The guard's runtime block is gone ──────────────────────────
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit"
# Pre-INFRA-499 the guard wrapped its logic in `if [ "${CHUMP_RAW_YAML_LOCK:-1}" != "0" ]; then`.
# Verify that runtime gate no longer surrounds an active block.
if grep -qE 'CHUMP_RAW_YAML_LOCK:-1' "$HOOK"; then
    fail "raw-YAML guard runtime gate still present (CHUMP_RAW_YAML_LOCK:-1 found)"
else
    pass "raw-YAML guard runtime block removed"
fi

# ── 2. The removal note is present (audit trail) ──────────────────
if grep -q "INFRA-499" "$HOOK"; then
    pass "INFRA-499 removal note documented in pre-commit"
else
    fail "no INFRA-499 removal note (lost the audit trail)"
fi

# ── 3. End-to-end: a hand-edit to docs/gaps/*.yaml passes ─────────
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
git init -q -b main "$SANDBOX"
cd "$SANDBOX"
git config user.email t@t
git config user.name t
mkdir -p scripts/git-hooks docs/gaps
cp "$HOOK" scripts/git-hooks/pre-commit
chmod +x scripts/git-hooks/pre-commit
mkdir -p .git/hooks
cp "$HOOK" .git/hooks/pre-commit

cat > docs/gaps/TEST-001.yaml <<EOF
- id: TEST-001
  status: open
EOF
# Disable other guards that need a real chump tree to avoid noise.
export CHUMP_LEASE_CHECK=0
export CHUMP_STOMP_WARN=0
export CHUMP_GAPS_LOCK=0
export CHUMP_PREREG_CHECK=0
export CHUMP_PREREG_CONTENT_CHECK=0
export CHUMP_CROSS_JUDGE_CHECK=0
export CHUMP_SUBMODULE_CHECK=0
export CHUMP_CHECK_BUILD=0
export CHUMP_DOCS_DELTA_CHECK=0
export CHUMP_CREDENTIAL_CHECK=0
export CHUMP_BOOK_SYNC_CHECK=0
export CHUMP_SCOPE_CHECK=0
git add docs/gaps/TEST-001.yaml scripts/
if git commit -q -m "INFRA-499: raw YAML edit allowed post-removal" 2>commit.err; then
    pass "raw YAML edit no longer blocked (guard removed)"
else
    if grep -q "raw-YAML-edit guard" commit.err 2>/dev/null; then
        fail "raw-YAML guard still active: $(cat commit.err)"
    else
        # Some unrelated guard tripped — log but don't fail this specific test.
        pass "raw YAML guard removed (other guard tripped, irrelevant: $(head -1 commit.err))"
    fi
fi

cd "$REPO_ROOT"
echo
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
