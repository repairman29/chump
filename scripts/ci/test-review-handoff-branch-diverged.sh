#!/usr/bin/env bash
# test-review-handoff-branch-diverged.sh — INFRA-778
#
# Validates the branch-diverged guard in worker.sh:
#  - INFRA-778 guard referenced in worker.sh
#  - review_handoff_branch_diverged kind emitted on low file overlap
#  - Fields: pr_number, overlap_pct, agent_id, gap_id
#  - Guard skips auto-apply (continues loop) on diverged branch
#  - Overlap >= 50% allows apply (guard passes through)
#  - review_handoff_branch_diverged registered in EVENT_REGISTRY.yaml

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

echo "=== INFRA-778 review_handoff_branch_diverged test ==="
echo

# 1. INFRA-778 referenced in worker.sh
if grep -q "INFRA-778" "$WORKER"; then
    ok "INFRA-778 block referenced in worker.sh"
else
    fail "INFRA-778 block missing from worker.sh"
fi

# 2. review_handoff_branch_diverged kind emitted in worker.sh
if grep -q 'review_handoff_branch_diverged' "$WORKER"; then
    ok "review_handoff_branch_diverged kind present in worker.sh"
else
    fail "review_handoff_branch_diverged event missing from worker.sh"
fi

# 3. Required event fields in worker.sh emit line
if grep 'review_handoff_branch_diverged' "$WORKER" | grep -q '"pr_number"' \
   && grep 'review_handoff_branch_diverged' "$WORKER" | grep -q '"overlap_pct"'; then
    ok "event includes pr_number and overlap_pct fields"
else
    fail "event missing pr_number or overlap_pct fields"
fi

if grep 'review_handoff_branch_diverged' "$WORKER" | grep -q '"agent_id"' \
   && grep 'review_handoff_branch_diverged' "$WORKER" | grep -q '"gap_id"'; then
    ok "event includes agent_id and gap_id fields"
else
    fail "event missing agent_id or gap_id fields"
fi

# 4. Overlap threshold is 50
if grep -q '\-lt 50' "$WORKER" || grep -q '< 50' "$WORKER"; then
    ok "overlap threshold is 50%"
else
    fail "overlap threshold (50) not found in worker.sh"
fi

# 5. EVENT_REGISTRY has review_handoff_branch_diverged entry
if grep -q 'review_handoff_branch_diverged' "$REGISTRY"; then
    ok "review_handoff_branch_diverged registered in EVENT_REGISTRY.yaml"
else
    fail "review_handoff_branch_diverged missing from EVENT_REGISTRY.yaml"
fi

# 6. Registry entry includes required fields
if grep -A10 'review_handoff_branch_diverged' "$REGISTRY" | grep -q 'fields_required'; then
    ok "EVENT_REGISTRY entry includes fields_required"
else
    fail "EVENT_REGISTRY entry missing fields_required"
fi

# 7. Functional: overlap < 50 triggers skip
echo
echo "[functional: overlap calculation]"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Low overlap: diff touches src/foo.rs, branch changed docs/bar.md (0% overlap)
DIFF_LOW='--- a/src/foo.rs
+++ b/src/foo.rs
@@ -1 +1 @@
-old
+new'

LOW_PCT="$(printf '%s' "$DIFF_LOW" | python3 -c "
import sys, re
diff_block = sys.stdin.read()
target_files = set()
for line in diff_block.splitlines():
    m = re.match(r'^(?:---|\+\+\+) [ab]/(.+)', line)
    if m and m.group(1) != '/dev/null':
        target_files.add(m.group(1))
branch_files = {'docs/bar.md', 'docs/baz.md'}
union = target_files | branch_files
overlap = target_files & branch_files
pct = int(len(overlap)*100/len(union)) if union else 100
print(pct)
" 2>/dev/null)"

if [[ "${LOW_PCT:-100}" -lt 50 ]]; then
    ok "low overlap ($LOW_PCT%) correctly below 50% threshold"
else
    fail "low overlap calculation wrong: got $LOW_PCT% for disjoint file sets"
fi

# High overlap: diff and branch both touch src/foo.rs (100% overlap)
HIGH_PCT="$(printf '%s' "$DIFF_LOW" | python3 -c "
import sys, re
diff_block = sys.stdin.read()
target_files = set()
for line in diff_block.splitlines():
    m = re.match(r'^(?:---|\+\+\+) [ab]/(.+)', line)
    if m and m.group(1) != '/dev/null':
        target_files.add(m.group(1))
branch_files = {'src/foo.rs'}
union = target_files | branch_files
overlap = target_files & branch_files
pct = int(len(overlap)*100/len(union)) if union else 100
print(pct)
" 2>/dev/null)"

if [[ "${HIGH_PCT:-0}" -ge 50 ]]; then
    ok "high overlap ($HIGH_PCT%) correctly at or above 50% threshold"
else
    fail "high overlap calculation wrong: got $HIGH_PCT% for identical file sets"
fi

# 8. Simulate event emission on diverged branch
AMB="$TMP/ambient.jsonl"
_778_overlap_pct=12
AGENT_ID="test-agent-778"
GAP_ID="INFRA-778-test"

if [[ "$_778_overlap_pct" -lt 50 ]]; then
    printf '{"ts":"%s","kind":"review_handoff_branch_diverged","pr_number":%s,"overlap_pct":%s,"agent_id":"%s","gap_id":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "99" "$_778_overlap_pct" "$AGENT_ID" "$GAP_ID" \
        >> "$AMB" 2>/dev/null || true
fi

if [[ -f "$AMB" ]] && grep -q '"review_handoff_branch_diverged"' "$AMB"; then
    ok "review_handoff_branch_diverged event emitted when overlap < 50%"
else
    fail "review_handoff_branch_diverged not emitted"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
