#!/usr/bin/env bash
# test-doctrine-delta-inject.sh — META-292 smoke test for
# scripts/coord/doctrine-delta-inject.sh
#
# Seeds a fake last-doctrine-commit pointing at 2 commits ago (relative to
# the newest commit that touches CLAUDE.md/AGENTS.md/docs/process/*.md/
# docs/MISSION.md), runs the injector, and asserts the digest contains
# those doctrine commits in human-readable form.
#
# Run from repo root: bash scripts/ci/test-doctrine-delta-inject.sh

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
STATE_FILE="$SANDBOX/session-last-doctrine-commit"

git fetch origin main --quiet 2>/dev/null || true

# Find the two most-recent commits that touch doctrine paths.
DOCTRINE_SHAS=$(git log --format=%H -n 2 origin/main -- \
    CLAUDE.md AGENTS.md docs/process/*.md docs/MISSION.md 2>/dev/null)

if [[ -z "$DOCTRINE_SHAS" ]]; then
    echo "SKIP: no doctrine-path commits found on origin/main — nothing to assert against"
    exit 0
fi

NEWEST_DOCTRINE_SHA=$(echo "$DOCTRINE_SHAS" | head -1)
# Seed watermark at the parent of the OLDER of the two most-recent doctrine
# commits, so both land inside the delta window.
OLDER_DOCTRINE_SHA=$(echo "$DOCTRINE_SHAS" | sed -n '2p')
if [[ -z "$OLDER_DOCTRINE_SHA" ]]; then
    OLDER_DOCTRINE_SHA="$NEWEST_DOCTRINE_SHA"
fi
SEED_SHA=$(git rev-parse "${OLDER_DOCTRINE_SHA}^" 2>/dev/null || echo "$OLDER_DOCTRINE_SHA")
echo "$SEED_SHA" > "$STATE_FILE"

OUTPUT=$(CHUMP_DOCTRINE_DELTA_STATE="$STATE_FILE" bash scripts/coord/doctrine-delta-inject.sh </dev/null)

# 1. Output must be valid JSON with the expected hookSpecificOutput shape.
if echo "$OUTPUT" | python3 -c 'import json,sys; o=json.load(sys.stdin); assert o["hookSpecificOutput"]["hookEventName"]=="SessionStart"' 2>/dev/null; then
    pass "output is valid SessionStart hook JSON"
else
    fail "output is NOT valid SessionStart hook JSON: $OUTPUT"
fi

CONTEXT=$(echo "$OUTPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null || echo "")

if echo "$CONTEXT" | grep -q "Doctrine changes since your last session"; then
    pass "digest contains the doctrine-changes header"
else
    fail "digest missing doctrine-changes header: $CONTEXT"
fi

SHORT_NEWEST="${NEWEST_DOCTRINE_SHA:0:7}"
if echo "$CONTEXT" | grep -q "$SHORT_NEWEST"; then
    pass "digest contains newest doctrine commit ($SHORT_NEWEST)"
else
    fail "digest missing newest doctrine commit ($SHORT_NEWEST): $CONTEXT"
fi

SHORT_OLDER="${OLDER_DOCTRINE_SHA:0:7}"
if echo "$CONTEXT" | grep -q "$SHORT_OLDER"; then
    pass "digest contains older doctrine commit ($SHORT_OLDER)"
else
    fail "digest missing older doctrine commit ($SHORT_OLDER): $CONTEXT"
fi

# 2. Watermark must have been advanced to origin/main HEAD after the run.
HEAD_SHA=$(git rev-parse origin/main)
STORED_AFTER=$(head -1 "$STATE_FILE" 2>/dev/null | xargs)
if [[ "$STORED_AFTER" == "$HEAD_SHA" ]]; then
    pass "watermark advanced to origin/main HEAD"
else
    fail "watermark not advanced: expected $HEAD_SHA, got $STORED_AFTER"
fi

# 3. No-op run (watermark == HEAD) must produce empty additionalContext.
OUTPUT2=$(CHUMP_DOCTRINE_DELTA_STATE="$STATE_FILE" bash scripts/coord/doctrine-delta-inject.sh </dev/null)
CONTEXT2=$(echo "$OUTPUT2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null || echo "MISSING")
if [[ -z "$CONTEXT2" ]]; then
    pass "second run (no new doctrine commits) produces empty additionalContext"
else
    fail "second run should be empty, got: $CONTEXT2"
fi

# 4. Directive-freshness sub-check: a stale file:line reference is flagged.
STATE_FILE2="$SANDBOX/session-last-doctrine-commit-2"
echo "$SEED_SHA" > "$STATE_FILE2"
DIRECTIVE_OUT=$(printf '{"directive":"fix line 1 in scripts/coord/doctrine-delta-inject.sh"}' | \
    CHUMP_DOCTRINE_DELTA_STATE="$STATE_FILE2" bash scripts/coord/doctrine-delta-inject.sh)
DIRECTIVE_CONTEXT=$(echo "$DIRECTIVE_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null || echo "")
if echo "$DIRECTIVE_CONTEXT" | grep -q "Directive freshness"; then
    pass "directive freshness sub-check fires on file:line reference"
else
    fail "directive freshness sub-check did not fire: $DIRECTIVE_CONTEXT"
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
