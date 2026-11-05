#!/usr/bin/env bash
# CREDIBLE-1526: server-side review hold — check script, HELD list, workflow wiring.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
fail() { echo "FAIL: $*" >&2; exit 1; }

# AC1: ESCALATE label => check fails; cleared => passes; unreadable => fails closed.
bash scripts/ci/review-hold-check.sh '["review-held"]' 2>/dev/null && fail "review-held must fail the check"
bash scripts/ci/review-hold-check.sh '["Review-Needs-Mutants","x"]' 2>/dev/null && fail "review-needs-mutants must fail"
bash scripts/ci/review-hold-check.sh '["bug"]' >/dev/null || fail "unheld PR must pass"
bash scripts/ci/review-hold-check.sh '[]' >/dev/null || fail "no labels must pass"
bash scripts/ci/review-hold-check.sh 'not-json' 2>/dev/null && fail "unreadable must fail closed"

# AC1: workflow is a job named review-hold that re-runs on label changes.
grep -q 'review-hold:' .github/workflows/review-hold.yml || fail "job missing"
grep -q 'labeled' .github/workflows/review-hold.yml || fail "must trigger on labeled"
grep -q 'unlabeled' .github/workflows/review-hold.yml || fail "must trigger on unlabeled"

# AC3: HELD list with diff stat.
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
echo '[{"number":5581,"title":"RESILIENT-1619 pre-push hook","additions":42,"deletions":3,"changedFiles":2}]' > "$tmp"
out="$(CHUMP_REVIEW_HELD_JSON="$tmp" bash scripts/coord/review-held-list.sh)"
grep -q '#5581' <<<"$out" && grep -q '+42/-3, 2 files' <<<"$out" || fail "held list missing PR/diff stat: $out"
echo '[]' > "$tmp"
[[ -z "$(CHUMP_REVIEW_HELD_JSON="$tmp" bash scripts/coord/review-held-list.sh)" ]] || fail "empty list must print nothing"
grep -q 'review-held-list.sh' scripts/dispatch/fleet-brief.sh || fail "fleet-brief.sh not wired"
grep -q 'review-held-list.sh' scripts/coord/ambient-context-inject.sh || fail "SessionStart digest not wired"
grep -q 'review-held-list.sh' src/main.rs || fail "chump fleet brief not wired"

# AC4: baseline + docs.
grep -q '"review-hold"' docs/baselines/branch-protection-main.json || fail "baseline missing review-hold"
grep -q 'Server-side review hold' docs/process/CODEREVIEW_POLICY.md || fail "policy doc missing"
echo "ok: review-hold server-side (CREDIBLE-1526)"
