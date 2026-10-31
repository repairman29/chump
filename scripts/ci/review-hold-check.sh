#!/usr/bin/env bash
# scripts/ci/review-hold-check.sh — CREDIBLE-1526 (PHASE-R R3): server-side review hold.
#
# Backs the required status check `review-hold` (.github/workflows/review-hold.yml).
# Reads the PR's labels (JSON array of label names on stdin or $1) and FAILS when
# the independent reviewer (code-reviewer-agent.sh / review organ) has held the PR
# with `review-held` or `review-needs-mutants`. Because the check is a REQUIRED
# status in branch protection, a held PR cannot merge even if some script armed
# auto-merge — the verdict no longer lives only in the client.
#
# Usage: review-hold-check.sh '["bug","review-held"]'   (exit 0 = clear, 1 = held)
set -euo pipefail
labels="${1:-$(cat)}"
held="$(printf '%s' "$labels" | python3 -c '
import json, sys
try:
    names = json.load(sys.stdin)
except Exception:
    names = None
if names is None:
    print("unreadable"); sys.exit(0)
hold = {"review-held", "review-needs-mutants"}
print(",".join(sorted(n for n in names if isinstance(n, str) and n.lower() in hold)))
')"
if [[ "$held" == "unreadable" ]]; then
    echo "review-hold: cannot read labels — failing closed" >&2
    exit 1
fi
if [[ -n "$held" ]]; then
    echo "review-hold: PR is HELD by independent review (label: $held). A human approval (or a VERDICT: APPROVE from the review organ, which removes the label) is required." >&2
    exit 1
fi
echo "review-hold: clear"
