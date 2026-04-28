#!/usr/bin/env bash
# INFRA-113: tests for the preregistration content checker
# (scripts/ci/check-prereg-content.py). Validates that empty / stub
# preregistration files fail and a fully-populated file passes.
# Run from repo root: bash scripts/ci/test-prereg-content-guard.sh

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

CHECKER="$REPO_ROOT/scripts/ci/check-prereg-content.py"
[ -x "$CHECKER" ] || { echo "[FATAL] checker not executable: $CHECKER" >&2; exit 2; }

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# Convenience: run checker on stdin, swallow stderr unless TEST_VERBOSE=1.
run_checker() {
    local gid="$1"
    local content="$2"
    if [ "${TEST_VERBOSE:-0}" = "1" ]; then
        printf '%s' "$content" | python3 "$CHECKER" "$gid" --stdin
    else
        printf '%s' "$content" | python3 "$CHECKER" "$gid" --stdin 2>/dev/null
    fi
}

# ── case 1: empty file fails ─────────────────────────────────────────────────
if run_checker EVAL-TEST ""; then
    fail "empty preregistration unexpectedly passed"
else
    pass "empty preregistration fails"
fi

# ── case 2: one-line stub fails ──────────────────────────────────────────────
if run_checker EVAL-TEST "# Preregistration EVAL-TEST"; then
    fail "one-line stub unexpectedly passed"
else
    pass "one-line stub fails"
fi

# ── case 3: unfilled template fails ──────────────────────────────────────────
TEMPLATE_PATH="docs/eval/preregistered/TEMPLATE.md"
if [ ! -f "$TEMPLATE_PATH" ]; then
    fail "TEMPLATE.md missing — cannot exercise unfilled-template case"
else
    if run_checker EVAL-TEST "$(cat "$TEMPLATE_PATH")"; then
        fail "unfilled TEMPLATE.md unexpectedly passed"
    else
        pass "unfilled TEMPLATE.md fails"
    fi
fi

# ── case 4: fully-populated content passes ───────────────────────────────────
POPULATED=$(cat <<'EOF'
# Preregistration — EVAL-TEST

Status: LOCKED. See docs/RESEARCH_INTEGRITY.md for the prohibited-claims policy
that this preregistration attests to.

## 1. Gap reference

- Gap ID: EVAL-TEST
- Gap title: harness round-trip integrity check
- Author: jeffadkins
- Preregistration date: 2026-04-28

## 2. Hypothesis

Primary hypothesis: if the new harness is enabled, the round-trip mismatch
rate decreases by at least 0.05 (5 percentage points) relative to the
existing baseline harness.

Null hypothesis: mismatch rate is unchanged within A/A noise floor.

## 3. Design

### Cells
| Cell | Intervention |
|---|---|
| A | baseline harness (control) |
| B | new harness (treatment) |

### Sample size
- n per cell: 50
- Power: detects delta >= 0.05 at alpha=0.05 with power=0.80.

### Model & provider matrix
- LLM judge: GPT-4o (OpenAI), independent from the agent under test —
  per RESEARCH_INTEGRITY.md, an Anthropic-only judge panel is not used.
- Human judge subset: Jeff for 10% spot check.

## 4. Primary metric

mismatch_rate = sum(round_trip_mismatch) / n_trials

Reported with Wilson 95% CI.

## 5. Secondary metrics

- per-judge inter-rater kappa
- median runtime per trial

## 6. Stopping rule

Planned n=50 per cell. No interim peeks.

## 7. Analysis plan

Compute Δ = rate(A) − rate(B). Report against A/A baseline noise floor
from EVAL-042. Effect threshold: report only deltas with |Δ| >= 0.05.

## 8. Exclusion rules

Exclude trials whose harness errored before producing output.

## 9. Decision rule

If |Δ| >= 0.05 and Wilson CI excludes zero, declare effect. Otherwise
report null with explicit underpowered label if applicable.
EOF
)
if run_checker EVAL-TEST "$POPULATED"; then
    pass "fully-populated content passes"
else
    fail "fully-populated content unexpectedly failed"
fi

# ── case 5: real RESEARCH-018 prereg passes (regression guard) ───────────────
REAL_PATH="docs/eval/preregistered/RESEARCH-018.md"
if [ -f "$REAL_PATH" ]; then
    if python3 "$CHECKER" RESEARCH-018 "$REAL_PATH" 2>/dev/null; then
        pass "real RESEARCH-018 prereg passes"
    else
        fail "real RESEARCH-018 prereg now fails — checker is too strict"
    fi
fi

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
