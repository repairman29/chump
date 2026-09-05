#!/usr/bin/env bash
# scripts/ci/test-brier-score.sh — RESILIENT-973 (RESILIENT-422 slice)
#
# Proves scripts/coord/lib/calibration.sh's brier_score() is a standalone,
# domain-agnostic scorer: given two JSON arrays (predicted probabilities,
# binary outcomes) it returns a Brier score with no ledger/id/price
# machinery involved — usable for any prediction type, not only PR-merge
# bets.
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LIB="$REPO_ROOT/scripts/coord/lib/calibration.sh"
[[ -f "$LIB" ]] || { printf 'FATAL: %s not found\n' "$LIB" >&2; exit 1; }
# shellcheck source=lib/calibration.sh
source "$LIB"

PASS=0; FAIL=0
_ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
_fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

# ── 1. canonical two-prediction case matches calibration_settle's known value ──
BRIER="$(brier_score '[0.9, 0.2]' '[1, 0]')"
[[ "$BRIER" == "0.025" ]] && _ok "canonical case scores 0.025" \
  || _fail "expected 0.025, got $BRIER"

# ── 2. perfect forecaster scores 0.0 ─────────────────────────────────────────
BRIER="$(brier_score '[1.0, 0.0, 1.0]' '[1, 0, 1]')"
[[ "$BRIER" == "0" ]] && _ok "perfect forecaster scores 0" \
  || _fail "expected 0, got $BRIER"

# ── 3. maximally wrong forecaster scores 1.0 ─────────────────────────────────
BRIER="$(brier_score '[1.0, 0.0]' '[0, 1]')"
[[ "$BRIER" == "1" ]] && _ok "maximally wrong forecaster scores 1" \
  || _fail "expected 1, got $BRIER"

# ── 4. non-PR prediction type (e.g. a coin-flip weather forecast) ───────────
BRIER="$(brier_score '[0.5, 0.5, 0.5, 0.5]' '[1, 0, 1, 0]')"
[[ "$BRIER" == "0.25" ]] && _ok "always-0.5 forecaster scores 0.25 on a 50/50 mix" \
  || _fail "expected 0.25, got $BRIER"

# ── 5. empty arrays yield null, not a crash ──────────────────────────────────
BRIER="$(brier_score '[]' '[]')"
[[ "$BRIER" == "null" ]] && _ok "empty arrays yield null" \
  || _fail "expected null, got $BRIER"

# ── 6. mismatched lengths yield null (no misaligned scoring) ────────────────
BRIER="$(brier_score '[0.9, 0.2]' '[1]')"
[[ "$BRIER" == "null" ]] && _ok "mismatched-length arrays yield null" \
  || _fail "expected null, got $BRIER"

echo
if [[ $FAIL -eq 0 ]]; then echo "$PASS passed, 0 failed"; exit 0
else echo "$PASS passed, $FAIL failed"; exit 1
fi
