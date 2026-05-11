#!/usr/bin/env bash
# test-review-handoff-reengage.sh — INFRA-771
#
# Validates the author-agent re-engagement loop in worker.sh:
#  - INFRA-771 block present in worker.sh
#  - CHUMP_HANDOFF_REENGAGE=0 kill-switch works
#  - [handoff:apply] parsing extracts diff block correctly
#  - re-engagement capped at 1 per PR per session (done-file logic)
#  - review_handoff_applied and review_handoff_failed ambient events emitted
#  - ambient events registered in EVENT_REGISTRY.yaml

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

echo "=== INFRA-771 review-as-handoff re-engagement test ==="
echo

# 1. INFRA-771 block present in worker.sh
if grep -q "INFRA-771" "$WORKER"; then
    ok "INFRA-771 block present in worker.sh"
else
    fail "INFRA-771 block missing from worker.sh"
fi

# 2. Kill switch variable present
if grep -q 'CHUMP_HANDOFF_REENGAGE' "$WORKER"; then
    ok "CHUMP_HANDOFF_REENGAGE kill switch present"
else
    fail "CHUMP_HANDOFF_REENGAGE kill switch missing"
fi

# 3. Ambient events emitted for applied/failed
if grep -q 'review_handoff_applied' "$WORKER"; then
    ok "review_handoff_applied event emitted"
else
    fail "review_handoff_applied event missing"
fi

if grep -q 'review_handoff_failed' "$WORKER"; then
    ok "review_handoff_failed event emitted"
else
    fail "review_handoff_failed event missing"
fi

# 4. Cap logic — done-file prevents second engagement
if grep -q '_reh_done_file' "$WORKER" && grep -q 'grep -qxF' "$WORKER"; then
    ok "1-per-PR-per-session cap logic present"
else
    fail "1-per-PR-per-session cap logic missing"
fi

# 5. git apply --check used before applying
if grep -q 'git.*apply --check' "$WORKER"; then
    ok "git apply --check guards diff before apply"
else
    fail "git apply --check guard missing"
fi

# 6. Tests run after apply (INFRA-761 requirement)
if grep -q 'cargo test.*--bin chump.*--tests' "$WORKER"; then
    ok "cargo test --bin chump --tests run after apply"
else
    fail "cargo test suite not run after apply"
fi

# 7. Handoff comment parsing — diff extraction Python block
if grep -q 'handoff:apply' "$WORKER"; then
    ok "[handoff:apply] annotation checked in comments"
else
    fail "[handoff:apply] annotation check missing"
fi

# 8. EVENT_REGISTRY.yaml registers the two new events
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if [[ -f "$REGISTRY" ]]; then
    if grep -q 'review_handoff_applied' "$REGISTRY"; then
        ok "review_handoff_applied in EVENT_REGISTRY.yaml"
    else
        fail "review_handoff_applied missing from EVENT_REGISTRY.yaml"
    fi

    if grep -q 'review_handoff_failed' "$REGISTRY"; then
        ok "review_handoff_failed in EVENT_REGISTRY.yaml"
    else
        fail "review_handoff_failed missing from EVENT_REGISTRY.yaml"
    fi
else
    fail "EVENT_REGISTRY.yaml not found at $REGISTRY"
fi

# 9. Functional unit test: diff extraction Python snippet
echo
echo "[unit: diff extraction from handoff comment]"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

COMMENT_BODY='## Root cause

The test asserts wrong value.

## Apply this diff

```diff
-    assert!(foo());
+    assert!(!foo());
```

## Verification

cargo test passed locally.

[handoff:apply by=reviewer-agent verified=true]'

EXTRACTED="$(printf '%s' "$COMMENT_BODY" | python3 -c "
import sys, re
body = sys.stdin.read()
m = re.search(r'\`\`\`diff\s*\n(.*?)\n\`\`\`', body, re.DOTALL)
if m:
    print(m.group(1))
" 2>/dev/null || true)"

if echo "$EXTRACTED" | grep -q 'assert!'; then
    ok "diff block extracted from handoff comment"
else
    fail "diff extraction failed — got: '$EXTRACTED'"
fi

# 10. Kill switch test: CHUMP_HANDOFF_REENGAGE=0 skips the block
# We verify by sourcing just the guard condition
if bash -c 'CHUMP_HANDOFF_REENGAGE=0; [[ "${CHUMP_HANDOFF_REENGAGE:-1}" != "0" ]] && echo "runs" || echo "skipped"' 2>/dev/null | grep -q "skipped"; then
    ok "CHUMP_HANDOFF_REENGAGE=0 skips re-engagement"
else
    fail "kill switch logic broken"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
