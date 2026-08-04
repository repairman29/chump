#!/usr/bin/env bash
# test-botmerge-poisoned-branch.sh — INFRA-3532
#
# Guards bot-merge's INFRA-306 MERGED-check refinement: a MERGED PR for the push
# branch is a settled race ONLY when HEAD adds no content over main. Branch-name
# reuse (a new slice of an already-shipped gap re-claiming chump/<id>-claim) also
# hits a MERGED state but carries a real diff — and the old code exited 0, silently
# shipping nothing. The fix discriminates by `git diff --quiet origin/main HEAD`
# (content, robust to squash-merge SHA rewrites) and fails loud (exit 22) with the
# recovery runbook on the reuse case.
#
# DEPTH: decision-table unit + structural guard.
#   - Covered: the (state, diff-empty) -> skip|poisoned|proceed decision, and that the
#     live script carries the content-based check + the non-zero exit + recovery text.
#   - GAP (not covered): does not run bot-merge end-to-end against a real merged PR +
#     reused branch (needs a live remote); the squash-merge false-positive it guards
#     against is argued, not exercised against a real squash.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../coord/bot-merge.sh"
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; else echo "  FAIL: $1 — expected [$2] got [$3]"; fail=1; fi; }

# Mirror of the INFRA-306 decision. $1=PR state, $2=diff_empty (1 if HEAD==main tree).
decide() {
    local state="$1" diff_empty="$2"
    if [[ "$state" == "MERGED" ]]; then
        if [[ "$diff_empty" == "1" ]]; then echo "skip"; else echo "poisoned"; fi
    else
        echo "proceed"
    fi
}

echo "test-botmerge-poisoned-branch (INFRA-3532):"

# 1. Settled race: MERGED + HEAD adds nothing over main -> skip (exit 0, current behaviour kept).
check "MERGED + empty diff -> skip" "skip" "$(decide MERGED 1)"

# 2. Poisoned reuse: MERGED + HEAD carries a real diff -> fail loud (the bug this fixes).
check "MERGED + real diff -> poisoned" "poisoned" "$(decide MERGED 0)"

# 3. Normal first-ship: no merged PR -> proceed regardless of diff.
check "OPEN state -> proceed" "proceed" "$(decide OPEN 0)"
check "empty state -> proceed" "proceed" "$(decide '' 0)"

# 4. Structural guard: the live script uses the CONTENT check (not a rev-list count),
#    fails non-zero on reuse, and prints the fresh-branch recovery.
if grep -q 'git diff --quiet origin/main HEAD' "$SCRIPT" \
   && grep -q 'INFRA-3532: .* has a MERGED PR but HEAD carries an unshipped diff' "$SCRIPT" \
   && grep -q 'exit 22' "$SCRIPT" \
   && grep -q 'Bot-Merge-Bypass: multi-slice branch reuse' "$SCRIPT"; then
    echo "  ok: live script has the content-based check + loud exit + recovery runbook"
else
    echo "  FAIL: INFRA-3532 guard missing/incomplete in $SCRIPT"; fail=1
fi

# 5. Regression guard: the settled-race skip path (exit 0) is preserved.
if grep -q 'already MERGED and HEAD adds nothing over main — skipping force-push' "$SCRIPT"; then
    echo "  ok: settled-race skip path preserved"
else
    echo "  FAIL: settled-race skip path lost"; fail=1
fi

if [[ $fail -eq 0 ]]; then echo "PASS"; else echo "FAILED"; exit 1; fi
