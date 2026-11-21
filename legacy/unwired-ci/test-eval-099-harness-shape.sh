#!/usr/bin/env bash
# test-eval-099-harness-shape.sh — EVAL-099
#
# Static-validates the COG-041 quality eval harness + preregistration.
# Mirrors EVAL-098's shape test. Doesn't run cargo or live ambient
# parsing — that's the post-merge operation.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
HARNESS="$REPO_ROOT/scripts/eval/cog-041-quality-vs-recency.sh"
PREREG="$REPO_ROOT/docs/eval/preregistered/EVAL-099.md"

echo "=== EVAL-099 harness shape + preregistration test ==="
echo

# --- Harness exists + bash-syntax-valid ---
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

# --- Harness reads BOTH live ambient and rotated archives (INFRA-122) ---
if grep -q 'ambient.jsonl.\*\.gz' "$HARNESS" \
   && grep -q 'gunzip -c' "$HARNESS"; then
    ok "harness reads live ambient.jsonl + rotated .gz archives"
else
    fail "harness does not read rotated archives — long-horizon data missed"
fi

# --- Decision rule matches the prereg threshold ---
if grep -qE 'n_A >= 30 AND n_B >= 30' "$HARNESS" \
   || grep -qE 'n_A >= 30.*n_B >= 30' "$HARNESS"; then
    ok "decision rule enforces n>=30 per cell (matches prereg)"
else
    fail "decision rule does not enforce n>=30"
fi

if grep -qE 'delta_pp >= 10' "$HARNESS"; then
    ok "decision rule uses +10pp threshold (matches prereg)"
else
    fail "decision rule threshold mismatch"
fi

# --- Insufficient-data path is explicit ---
if grep -q 'INSUFFICIENT_DATA' "$HARNESS"; then
    ok "harness has explicit INSUFFICIENT_DATA verdict path"
else
    fail "no INSUFFICIENT_DATA path — harness might force a verdict on tiny n"
fi

# --- Fallback rate diagnostic present ---
if grep -q 'recency_fallback_from_semantic' "$HARNESS"; then
    ok "harness reports semantic-fallback rate (Mode-C diagnostic)"
else
    fail "no fallback-rate diagnostic — can't tell if semantic was actually used"
fi

# --- Pairing window matches prereg (7 days) ---
if grep -qE 'PAIRING_WINDOW = timedelta\(days=7\)' "$HARNESS"; then
    ok "pairing window is 7 days (matches prereg)"
else
    fail "pairing window doesn't match prereg's 7-day rule"
fi

# --- Preregistration exists + has required sections ---
if [[ -f "$PREREG" ]]; then
    ok "preregistration exists at $PREREG"

    has_hypothesis=0
    has_n=0
    has_decision=0
    has_judge=0
    has_prohibited=0
    grep -qE '^## 2\. Hypothesis' "$PREREG" && has_hypothesis=1
    grep -qE 'Sample size|n per cell|Minimum n' "$PREREG" && has_n=1
    grep -qE 'Decision rule|H1 accepted iff' "$PREREG" && has_decision=1
    grep -qE 'single_judge_waived|cross_judge|LLM judge' "$PREREG" && has_judge=1
    grep -qE 'Prohibited claims|CANNOT claim' "$PREREG" && has_prohibited=1

    if [[ $has_hypothesis -eq 1 && $has_n -eq 1 && $has_decision -eq 1 \
        && $has_judge -eq 1 && $has_prohibited -eq 1 ]]; then
        ok "preregistration has all required sections"
    else
        fail "prereg missing sections: hyp=$has_hypothesis n=$has_n dec=$has_decision judge=$has_judge prohib=$has_prohibited"
    fi
else
    fail "preregistration missing"
fi

# --- Prohibited-claims explicitly forbid 'flip default' ---
if grep -qiE 'flip the default|default flip|provably best' "$PREREG"; then
    ok "prereg explicitly prohibits unsanctioned default-flip / 'best' claims"
else
    fail "prereg should explicitly forbid unsanctioned default flip"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
