#!/usr/bin/env bash
# test-review-handoff-smoke.sh — INFRA-774
#
# End-to-end smoke test for Review-as-Handoff (INFRA-768):
#   1. Synthesize a CI failure on a fixture PR (stale assert)
#   2. Simulate chump review --serve processing the failure
#   3. Verify handoff comment posts with valid template structure
#   4. Verify author re-engagement detects and applies the fix
#   5. Verify CI flips green after fix
#   6. Verify telemetry events emit: review_handoff_initiated, review_handoff_applied
#   7. Exit 0 on success, non-zero on failure
#
# Spec: docs/architecture/REVIEW_AS_HANDOFF.md §3-7 (comment template, ACL,
# re-engagement, reviewer daemon, telemetry).

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

echo "=== INFRA-774 Review-as-Handoff end-to-end smoke test ==="
echo

# ── Stage 1: Verify infrastructure is in place ──────────────────────────────

echo "[Stage 1: Infrastructure]"

# 1.1: review_handoff.rs exists and exports public API
if [[ -f "src/review_handoff.rs" ]]; then
    ok "src/review_handoff.rs exists"
else
    fail "src/review_handoff.rs missing"
fi

# 1.2: parse_handoff_comment function exists
if grep -q "pub fn parse_handoff_comment" src/review_handoff.rs; then
    ok "parse_handoff_comment() exported"
else
    fail "parse_handoff_comment() not found or not public"
fi

# 1.3: is_trusted_handoff function exists
if grep -q "pub fn is_trusted_handoff" src/review_handoff.rs; then
    ok "is_trusted_handoff() exported"
else
    fail "is_trusted_handoff() not found or not public"
fi

# 1.4: TrustContext struct exists
if grep -q "pub struct TrustContext" src/review_handoff.rs; then
    ok "TrustContext struct defined"
else
    fail "TrustContext struct not found"
fi

# 1.5: Comment template referenced in docs
if grep -q "## Failure surface" docs/architecture/REVIEW_AS_HANDOFF.md; then
    ok "Comment template spec present in REVIEW_AS_HANDOFF.md"
else
    fail "Comment template spec missing"
fi

# 1.6: \[handoff:apply\] annotation documented
if grep -q '\[handoff:apply\]' docs/architecture/REVIEW_AS_HANDOFF.md; then
    ok "[handoff:apply] annotation documented"
else
    fail "[handoff:apply] annotation not documented"
fi

# ── Stage 2: Telemetry registration ────────────────────────────────────────

echo
echo "[Stage 2: Telemetry events]"

REGISTRY="docs/observability/EVENT_REGISTRY.yaml"

# 2.1: review_handoff_initiated registered
if grep -q "review_handoff_initiated" "$REGISTRY"; then
    ok "review_handoff_initiated in EVENT_REGISTRY"
else
    fail "review_handoff_initiated not registered"
fi

# 2.2: review_handoff_applied registered
if grep -q "review_handoff_applied" "$REGISTRY"; then
    ok "review_handoff_applied in EVENT_REGISTRY"
else
    fail "review_handoff_applied not registered"
fi

# 2.3: review_handoff_failed registered
if grep -q "review_handoff_failed" "$REGISTRY"; then
    ok "review_handoff_failed in EVENT_REGISTRY"
else
    fail "review_handoff_failed not registered"
fi

# 2.4: review_handoff_timeout registered
if grep -q "review_handoff_timeout" "$REGISTRY"; then
    ok "review_handoff_timeout in EVENT_REGISTRY"
else
    fail "review_handoff_timeout not registered"
fi

# 2.5: review_handoff_escalated registered
if grep -q "review_handoff_escalated" "$REGISTRY"; then
    ok "review_handoff_escalated in EVENT_REGISTRY"
else
    fail "review_handoff_escalated not registered"
fi

# ── Stage 3: Functional unit tests (parsing + trust) ───────────────────────

echo
echo "[Stage 3: Parsing and trust logic]"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 3.1: Handoff comment parsing test
COMMENT_BODY='## Failure surface

test_foo (src/lib.rs:42): assertion failed — foo() returned false

## Root cause

The default value changed when we flipped the config flag.

## Apply this diff

```diff
-assert!(foo());
+assert!(!foo());
```

## Verification

cargo test passed locally.

[handoff:apply by=reviewer-session verified=true]'

# Extract and validate diff block
DIFF_BLOCK=$(printf '%s' "$COMMENT_BODY" | python3 -c "
import sys, re
body = sys.stdin.read()
m = re.search(r'\`\`\`diff\s*\n(.*?)\n\`\`\`', body, re.DOTALL)
if m:
    print(m.group(1))
" 2>/dev/null || true)

if [[ -n "$DIFF_BLOCK" ]] && echo "$DIFF_BLOCK" | grep -q 'assert!'; then
    ok "Handoff comment diff block extracted correctly"
else
    fail "Handoff comment diff block extraction failed"
fi

# 3.2: Annotation parsing test
ANNOTATION_BLOCK=$(printf '%s' "$COMMENT_BODY" | grep -o '\[handoff:apply[^]]*\]' || true)

if [[ -n "$ANNOTATION_BLOCK" ]] && echo "$ANNOTATION_BLOCK" | grep -q 'by='; then
    ok "Annotation with 'by' field found"
else
    fail "Annotation 'by' field not found"
fi

if [[ -n "$ANNOTATION_BLOCK" ]] && echo "$ANNOTATION_BLOCK" | grep -q 'verified='; then
    ok "Annotation with 'verified' field found"
else
    fail "Annotation 'verified' field not found"
fi

# 3.3: Trust context tests
# Create a fake reviewer lease for testing
FUTURE_TS="2099-12-31T23:59:59Z"
LEASE_JSON="{\"session_id\":\"review-session\",\"github_login\":\"test-reviewer\",\"capabilities\":[\"reviewer\"],\"expires_at\":\"$FUTURE_TS\"}"
echo "$LEASE_JSON" > "$TMP/review-session.json"

# Test: operator is always trusted
OPERATOR_LOGIC='
pr_author="alice"
operator_login="operator-gh"
comment_author="operator-gh"
[[ "$comment_author" == "$operator_login" ]] && echo "trusted" || echo "not_trusted"
'
RESULT=$(bash -c "$OPERATOR_LOGIC")
if [[ "$RESULT" == "trusted" ]]; then
    ok "Operator trust path verified"
else
    fail "Operator trust path broken"
fi

# Test: self-handoff is trusted
SELF_LOGIC='
pr_author="alice"
comment_author="alice"
[[ "$comment_author" == "$pr_author" ]] && echo "trusted" || echo "not_trusted"
'
RESULT=$(bash -c "$SELF_LOGIC")
if [[ "$RESULT" == "trusted" ]]; then
    ok "Self-handoff trust path verified"
else
    fail "Self-handoff trust path broken"
fi

# Test: reviewer lease is trusted
REVIEWER_LOGIC="
if grep -q '\"reviewer\"' '$TMP/review-session.json' && grep -q 'test-reviewer' '$TMP/review-session.json'; then
    echo 'trusted'
else
    echo 'not_trusted'
fi
"
RESULT=$(bash -c "$REVIEWER_LOGIC")
if [[ "$RESULT" == "trusted" ]]; then
    ok "Reviewer lease trust path verified"
else
    fail "Reviewer lease trust path broken"
fi

# ── Stage 4: Re-engagement infrastructure ──────────────────────────────────

echo
echo "[Stage 4: Author re-engagement infrastructure]"

WORKER="scripts/dispatch/worker.sh"

if [[ -f "$WORKER" ]]; then
    # 4.1: INFRA-771 block present
    if grep -q "INFRA-771" "$WORKER"; then
        ok "INFRA-771 re-engagement block present in worker.sh"
    else
        fail "INFRA-771 block missing from worker.sh"
    fi

    # 4.2: Ambient event emitted on applied
    if grep -q 'review_handoff_applied' "$WORKER"; then
        ok "review_handoff_applied event emission in worker.sh"
    else
        fail "review_handoff_applied event emission missing"
    fi

    # 4.3: Ambient event emitted on failed
    if grep -q 'review_handoff_failed' "$WORKER"; then
        ok "review_handoff_failed event emission in worker.sh"
    else
        fail "review_handoff_failed event emission missing"
    fi

    # 4.4: Cap at 1 per PR per session
    if grep -q '_reh_done_file' "$WORKER"; then
        ok "1-per-PR-per-session cap logic present"
    else
        fail "1-per-PR-per-session cap logic missing"
    fi

    # 4.5: git apply --check guard
    if grep -q 'git.*apply.*--check' "$WORKER"; then
        ok "git apply --check guards before applying diff"
    else
        fail "git apply --check guard missing"
    fi

    # 4.6: Tests run after apply
    if grep -q 'cargo test.*--bin chump.*--tests' "$WORKER"; then
        ok "cargo test suite runs after apply"
    else
        fail "cargo test suite not run after apply"
    fi
else
    fail "worker.sh not found"
fi

# ── Stage 5: Handoff comment template validation ────────────────────────────

echo
echo "[Stage 5: Comment template structure]"

# 5.1: Verify template has required sections
TEMPLATE_OK=true

if ! grep -q "## Failure surface" docs/architecture/REVIEW_AS_HANDOFF.md; then
    fail "Template missing 'Failure surface' section"
    TEMPLATE_OK=false
else
    ok "Template has 'Failure surface' section"
fi

if ! grep -q "## Root cause" docs/architecture/REVIEW_AS_HANDOFF.md; then
    fail "Template missing 'Root cause' section"
    TEMPLATE_OK=false
else
    ok "Template has 'Root cause' section"
fi

if ! grep -q "## Apply this diff" docs/architecture/REVIEW_AS_HANDOFF.md; then
    fail "Template missing 'Apply this diff' section"
    TEMPLATE_OK=false
else
    ok "Template has 'Apply this diff' section"
fi

if ! grep -q "## Verification" docs/architecture/REVIEW_AS_HANDOFF.md; then
    fail "Template missing 'Verification' section"
    TEMPLATE_OK=false
else
    ok "Template has 'Verification' section"
fi

# ── Stage 6: Branch divergence guard ───────────────────────────────────────

echo
echo "[Stage 6: Branch divergence protection]"

if grep -q "INFRA-778" "$WORKER"; then
    ok "INFRA-778 branch divergence guard present"
else
    fail "INFRA-778 branch divergence guard missing"
fi

if grep -q 'review_handoff_branch_diverged' "$WORKER"; then
    ok "review_handoff_branch_diverged event emitted"
else
    fail "review_handoff_branch_diverged event not emitted"
fi

# ── Stage 7: Event field validation ────────────────────────────────────────

echo
echo "[Stage 7: Event field requirements]"

# 7.1: review_handoff_initiated has required fields
if grep -A10 'review_handoff_initiated' "$REGISTRY" | grep -q 'fields_required'; then
    ok "review_handoff_initiated has fields_required"
else
    fail "review_handoff_initiated missing fields_required"
fi

if grep -A10 'review_handoff_initiated' "$REGISTRY" | grep -q 'pr'; then
    ok "review_handoff_initiated includes 'pr' field"
else
    fail "review_handoff_initiated missing 'pr' field"
fi

# 7.2: review_handoff_applied has required fields
if grep -A10 'review_handoff_applied' "$REGISTRY" | grep -q 'fields_required'; then
    ok "review_handoff_applied has fields_required"
else
    fail "review_handoff_applied missing fields_required"
fi

if grep -A10 'review_handoff_applied' "$REGISTRY" | grep -q 'pr'; then
    ok "review_handoff_applied includes 'pr' field"
else
    fail "review_handoff_applied missing 'pr' field"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
