#!/usr/bin/env bash
# test-eval-098-harness-shape.sh — EVAL-098
#
# Static-validates the COG-041-validation harness has the right shape
# AND the preregistration is present (RESEARCH-019 / INFRA-113 require
# preregistration for EVAL gaps before data collection). Doesn't run
# the harness itself — that's a post-merge operation, gated behind
# the operator running it explicitly to commit telemetry.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
HARNESS="$REPO_ROOT/scripts/eval/cog-041-semantic-vs-recency.sh"
PREREG="$REPO_ROOT/docs/eval/preregistered/EVAL-098.md"

echo "=== EVAL-098 harness shape + preregistration test ==="
echo

# --- Test 1: harness exists + executable + syntactically valid bash ---
if [[ -x "$HARNESS" ]]; then
    ok "harness exists and is executable"
else
    fail "harness missing or not executable: $HARNESS"
fi

if bash -n "$HARNESS" 2>/dev/null; then
    ok "harness is syntactically valid bash"
else
    fail "harness has syntax errors"
fi

# --- Test 2: harness queries both modes (CHUMP_LESSONS_SEMANTIC=0 + 1) ---
if grep -qE 'CHUMP_LESSONS_SEMANTIC=0' "$HARNESS" \
   && grep -qE 'CHUMP_LESSONS_SEMANTIC=1' "$HARNESS"; then
    ok "harness exercises both ranking modes (=0 baseline, =1 semantic)"
else
    fail "harness does not run both modes"
fi

# --- Test 3: harness computes Jaccard, not just absolute counts ---
if grep -q 'jaccard' "$HARNESS"; then
    ok "harness computes Jaccard overlap"
else
    fail "harness does not compute Jaccard"
fi

# --- Test 4: preregistration exists ---
if [[ -f "$PREREG" ]]; then
    ok "preregistration exists at $PREREG"
else
    fail "preregistration missing — INFRA-113 content guard will block ship"
fi

# --- Test 5: preregistration has required content (per INFRA-113 guard) ---
if [[ -f "$PREREG" ]]; then
    has_hypothesis=0
    has_sample_size=0
    has_decision_rule=0
    has_judge_or_waiver=0
    has_prohibited=0
    grep -qE '## 2\. Hypothesis' "$PREREG" && has_hypothesis=1
    grep -qE 'Sample size|n per cell|^\*\*n:' "$PREREG" && has_sample_size=1
    grep -qE 'Decision rule|H1 accepted iff|verdict' "$PREREG" && has_decision_rule=1
    grep -qE 'single_judge_waived|cross_judge|LLM judge' "$PREREG" && has_judge_or_waiver=1
    grep -qE '## 6\. Prohibited claims|prohibited' "$PREREG" && has_prohibited=1

    if [[ $has_hypothesis -eq 1 && $has_sample_size -eq 1 \
        && $has_decision_rule -eq 1 && $has_judge_or_waiver -eq 1 \
        && $has_prohibited -eq 1 ]]; then
        ok "preregistration has all required sections (hypothesis, n, decision rule, judge/waiver, prohibited claims)"
    else
        fail "preregistration missing required sections: hyp=$has_hypothesis n=$has_sample_size dec=$has_decision_rule judge=$has_judge_or_waiver prohib=$has_prohibited"
    fi
fi

# --- Test 6: decision rule is binary AND uses the prereg threshold ---
if grep -qE 'fraction_meaningfully_different.*0\.50|f\+0 >= 0\.50' "$HARNESS"; then
    ok "harness decision rule matches prereg threshold (≥ 50%)"
else
    fail "harness decision rule doesn't match prereg threshold"
fi

# --- Test 7: prohibited-claims section explicitly forbids 'better' or 'flip default' ---
# Multi-line check: the prereg explicitly forbids "BETTER" or "flip the default" claims.
if grep -qiE 'BETTER|flip the default' "$PREREG" \
   && grep -qiE 'CANNOT claim|prohibited' "$PREREG"; then
    ok "prereg explicitly prohibits quality claims (this eval is divergence-only)"
else
    fail "prereg should explicitly state quality claims are out of scope"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
