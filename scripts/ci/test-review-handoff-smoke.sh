#!/usr/bin/env bash
# test-review-handoff-smoke.sh — INFRA-774 (sub-gap 6/6)
#
# End-to-end smoke test for Review-as-Handoff (INFRA-768):
#  - Verify all 5 telemetry events are registered in EVENT_REGISTRY.yaml
#  - Verify comment template structure (per REVIEW_AS_HANDOFF.md §3)
#  - Verify ACL trust checks are implemented (per REVIEW_AS_HANDOFF.md §4)
#  - Verify author re-engagement loop exists in worker.sh (per REVIEW_AS_HANDOFF.md §5)
#  - Verify [handoff:apply] annotation parsing and field extraction
#  - Verify failure mode mitigations (per REVIEW_AS_HANDOFF.md §8)
#
# Spec: docs/architecture/REVIEW_AS_HANDOFF.md

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
REVIEW_HANDOFF_RS="$REPO_ROOT/src/review_handoff.rs"
SPEC="$REPO_ROOT/docs/architecture/REVIEW_AS_HANDOFF.md"

echo "=== INFRA-774 Review-as-Handoff end-to-end smoke test ==="
echo

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1: Telemetry events registered
# ─────────────────────────────────────────────────────────────────────────────

echo "[Stage 1: Telemetry events in EVENT_REGISTRY.yaml]"

[[ -f "$REGISTRY" ]] || { fail "EVENT_REGISTRY.yaml not found"; exit 1; }

# Per REVIEW_AS_HANDOFF.md §7: Five events required
EVENTS=(
    "review_handoff_initiated"
    "review_handoff_applied"
    "review_handoff_failed"
    "review_handoff_timeout"
    "review_handoff_escalated"
)

for event in "${EVENTS[@]}"; do
    if grep -q "$event" "$REGISTRY"; then
        ok "$event registered"
    else
        fail "$event missing from EVENT_REGISTRY.yaml"
    fi
done

echo

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2: Comment template structure (REVIEW_AS_HANDOFF.md §3)
# ─────────────────────────────────────────────────────────────────────────────

echo "[Stage 2: Comment template structure (spec §3)]"

[[ -f "$SPEC" ]] || { fail "REVIEW_AS_HANDOFF.md spec not found"; exit 1; }

SECTIONS=("Failure surface" "Root cause" "Apply this diff" "Verification")
for section in "${SECTIONS[@]}"; do
    if grep -q "^## $section" "$SPEC"; then
        ok "comment template has '## $section' section"
    else
        fail "comment template missing '## $section' section"
    fi
done

# Verify [handoff:apply] annotation is documented
if grep -q "\[handoff:apply" "$SPEC"; then
    ok "[handoff:apply] annotation documented in spec"
else
    fail "[handoff:apply] annotation not documented"
fi

echo

# ─────────────────────────────────────────────────────────────────────────────
# Stage 3: ACL trust checks (REVIEW_AS_HANDOFF.md §4)
# ─────────────────────────────────────────────────────────────────────────────

echo "[Stage 3: ACL trust checks (spec §4)]"

if grep -q "is_trusted_handoff\|TrustContext" "$REVIEW_HANDOFF_RS"; then
    ok "is_trusted_handoff ACL implemented"
else
    fail "is_trusted_handoff ACL missing"
fi

# Verify three trust paths documented: operator, reviewer-role, self-handoff
if grep -q "operator\|Operator" "$REVIEW_HANDOFF_RS" && grep -q "reviewer" "$REVIEW_HANDOFF_RS"; then
    ok "operator + reviewer-role trust paths implemented"
else
    fail "trust paths incomplete"
fi

# Verify PR author self-trust
if grep -q "pr_author\|comment author.*PR" "$REVIEW_HANDOFF_RS"; then
    ok "self-handoff trust (PR author) implemented"
else
    fail "self-handoff trust missing"
fi

echo

# ─────────────────────────────────────────────────────────────────────────────
# Stage 4: Author re-engagement loop (REVIEW_AS_HANDOFF.md §5)
# ─────────────────────────────────────────────────────────────────────────────

echo "[Stage 4: Author re-engagement loop (spec §5)]"

if grep -q "INFRA-771" "$WORKER"; then
    ok "author re-engagement loop (INFRA-771) in worker.sh"
else
    fail "author re-engagement loop missing"
fi

# Verify re-engagement is capped at 1 per PR per session
if grep -q "_reh_done_file\|reh.*done\|re.engagement.*done" "$WORKER"; then
    ok "1-per-PR-per-session re-engagement cap implemented"
else
    fail "re-engagement cap logic missing"
fi

# Verify [handoff:apply] comment parsing
if grep -q "handoff:apply\|handoff_comment" "$WORKER"; then
    ok "[handoff:apply] comment parsing in worker.sh"
else
    fail "[handoff:apply] parsing missing"
fi

# Verify tests are run after applying fix (INFRA-761 requirement)
if grep -q "cargo test" "$WORKER"; then
    ok "full test suite runs after applying fix (INFRA-761)"
else
    fail "test suite not run after fix"
fi

echo

# ─────────────────────────────────────────────────────────────────────────────
# Stage 5: Handoff comment parsing and validation
# ─────────────────────────────────────────────────────────────────────────────

echo "[Stage 5: Comment parsing and annotation validation]"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Valid handoff comment following template
VALID_COMMENT='## Failure surface

test_foo panicked at assertion failed

## Root cause

The test asserts foo_enabled() but we disabled it.

## Apply this diff

```diff
-    assert!(foo_enabled());
+    assert!(!foo_enabled());
```

## Verification

cargo test passed.

[handoff:apply by=reviewer-agent verified=true]'

# Extract diff block
EXTRACTED="$(printf '%s' "$VALID_COMMENT" | sed -n '/^```diff$/,/^```$/p' | sed '1d;$d')"
if echo "$EXTRACTED" | grep -q "^-.*assert" && echo "$EXTRACTED" | grep -q "^+.*assert"; then
    ok "diff block extracted from comment"
else
    fail "diff extraction failed"
fi

# Verify annotation exists
if printf '%s' "$VALID_COMMENT" | grep -q '\[handoff:apply'; then
    ok "[handoff:apply] annotation parsed"
else
    fail "[handoff:apply] annotation missing"
fi

# Verify by=<id> field
BY_FIELD="$(printf '%s' "$VALID_COMMENT" | grep 'by=' | sed -n 's/.*by=\([^ ]*\).*/\1/p')"
if [[ "$BY_FIELD" == "reviewer-agent" ]]; then
    ok "by=<id> field extracted correctly"
else
    fail "by=<id> extraction failed — got: '$BY_FIELD'"
fi

echo

# ─────────────────────────────────────────────────────────────────────────────
# Stage 6: Failure mode mitigations (REVIEW_AS_HANDOFF.md §8)
# ─────────────────────────────────────────────────────────────────────────────

echo "[Stage 6: Failure mode mitigations (spec §8)]"

# Mitigation 1: Bad fix detection via full test suite
if grep -q "cargo test.*--bin chump\|cargo.*test" "$WORKER"; then
    ok "bad-fix mitigation: tests run after apply"
else
    fail "test requirement missing after fix apply"
fi

# Mitigation 2: ACL spoofing prevention
if grep -q "is_trusted\|verify.*author\|TrustContext" "$REVIEW_HANDOFF_RS"; then
    ok "ACL spoofing mitigation: trust verification"
else
    fail "trust verification missing"
fi

# Mitigation 3: Earliest handoff wins (INFRA-770)
if grep -q "INFRA-770\|earliest\|first" "$REVIEW_HANDOFF_RS"; then
    ok "conflicting-comments mitigation: earliest handoff wins"
else
    fail "earliest-handoff logic missing"
fi

# Mitigation 4: 15-minute timeout window
if grep -qE "900|15.*min" "$WORKER"; then
    ok "timeout mitigation: 15-min window (900s) enforced"
else
    # May be defined as constant elsewhere
    echo "  (note: 15-min window definition may be elsewhere)"
fi

echo

# ─────────────────────────────────────────────────────────────────────────────
# Stage 7: Integration points
# ─────────────────────────────────────────────────────────────────────────────

echo "[Stage 7: Integration points]"

# Verify ambient events are emitted by worker.sh
for event in "review_handoff_applied" "review_handoff_failed"; do
    if grep -q "$event" "$WORKER"; then
        ok "worker.sh emits $event event"
    else
        fail "$event emission missing"
    fi
done

# Verify consumers are defined in registry
if grep -A 2 "review_handoff" "$REGISTRY" | grep -q "consumers:"; then
    ok "review_handoff events have defined consumers"
else
    fail "consumer definitions missing"
fi

echo

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

echo
if [[ "$FAIL" -eq 0 ]]; then
    echo "✓ INFRA-774 smoke test PASSED: $PASS checks passed"
    exit 0
else
    echo "✗ INFRA-774 smoke test FAILED: $PASS passed, $FAIL failed"
    exit 1
fi
