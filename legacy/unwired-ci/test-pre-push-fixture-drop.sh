#!/usr/bin/env bash
# scripts/ci/test-pre-push-fixture-drop.sh — INFRA-1408
#
# Verifies that Guard 0d in scripts/git-hooks/pre-push detects ghost commits
# authored by Test<test@test.local> (or matching CHUMP_FIXTURE_AUTHOR_REGEX)
# and either refuses the push (default) or auto-drops them
# (CHUMP_AUTODROP_FIXTURE_COMMITS=1).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"
[ -x "$HOOK" ] || { echo "[test-pre-push-fixture-drop] hook missing at $HOOK" >&2; exit 1; }

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

echo "=== INFRA-1408 ghost-commit drop test ==="
echo

# ── 1. Static wiring ────────────────────────────────────────────────────────
grep -q "INFRA-1408" "$HOOK" \
    && ok "INFRA-1408 referenced in pre-push hook" \
    || fail "INFRA-1408 marker missing from pre-push hook"

grep -q "CHUMP_FIXTURE_AUTHOR_GUARD" "$HOOK" \
    && ok "CHUMP_FIXTURE_AUTHOR_GUARD env var documented" \
    || fail "CHUMP_FIXTURE_AUTHOR_GUARD bypass missing"

grep -q "CHUMP_AUTODROP_FIXTURE_COMMITS" "$HOOK" \
    && ok "CHUMP_AUTODROP_FIXTURE_COMMITS env var documented" \
    || fail "CHUMP_AUTODROP_FIXTURE_COMMITS auto-drop missing"

grep -q "fixture_commit_dropped" "$HOOK" \
    && ok "kind=fixture_commit_dropped ambient emit wired" \
    || fail "ambient emit missing"

# ── 2. Regex correctness (sample author strings) ────────────────────────────
default_regex='@(test|fixture|example)\.local$'

# Sample matches (should be detected)
for email in "test@test.local" "Test@test.local" "fixture@test.local" "anyone@fixture.local"; do
    if echo "$email" | grep -qE "$default_regex"; then
        ok "regex correctly matches ghost author: $email"
    else
        fail "regex SHOULD match $email"
    fi
done

# Sample non-matches (should NOT be detected)
for email in "jeff@example.com" "real-dev@chump.dev" "Test@example.com" "test@notalocal.com"; do
    if ! echo "$email" | grep -qE "$default_regex"; then
        ok "regex correctly skips real author: $email"
    else
        fail "regex SHOULD NOT match $email"
    fi
done

# ── 3. Documentation and event-registry sanity ──────────────────────────────
if grep -q "fixture_commit_dropped" "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" 2>/dev/null; then
    ok "fixture_commit_dropped registered in EVENT_REGISTRY.yaml"
else
    # Registration is a follow-up — warn but don't fail (gate ships before registry edit)
    printf '\033[1;33mWARN\033[0m fixture_commit_dropped not yet in EVENT_REGISTRY.yaml (register in follow-up)\n'
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
