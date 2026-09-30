#!/usr/bin/env bash
# test-ci-qa-accuracy-score.sh — INFRA-5753 smoke test.
#
# Exercises scripts/ops/ci-qa-accuracy-score.sh against a synthetic
# ambient.jsonl. Verifies:
#   1. CHUMP_CI_QA_ACCURACY_SCORE=0 bypasses cleanly (exit 0).
#   2. No classified events in window → score=null.
#   3. Mixed sample → correct accurate/fp/missed_locally/flake buckets and
#      score formula.
#   4. Events outside the window are excluded.
#   5. --dry-run does not write to ambient.jsonl.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/ci-qa-accuracy-score.sh"

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

AMBIENT="$TMP/ambient.jsonl"
touch "$AMBIENT"
export CHUMP_AMBIENT_LOG="$AMBIENT"

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
hours_ago_ts() {
    python3 -c "from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc) - timedelta(hours=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"
}

# ── Test 1: CHUMP_CI_QA_ACCURACY_SCORE=0 bypasses ────────────────────────────
echo "Test 1: CHUMP_CI_QA_ACCURACY_SCORE=0 bypasses"
out=$(CHUMP_CI_QA_ACCURACY_SCORE=0 "$SCRIPT" 2>&1)
if [[ "$out" == *"bypassed"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected 'bypassed' in output, got: $out"
    exit 1
fi

# ── Test 2: empty ambient → score=null ───────────────────────────────────────
echo "Test 2: no classified events → score=null"
> "$AMBIENT"
out=$("$SCRIPT" --json 2>&1)
if echo "$out" | grep -q '"score":null' && echo "$out" | grep -q '"accurate_failures":0'; then
    echo "  PASS"
else
    echo "  FAIL: expected score=null accurate_failures=0, got: $out"
    exit 1
fi

# ── Test 3: mixed sample → correct buckets + score ───────────────────────────
echo "Test 3: mixed sample computes correct score"
> "$AMBIENT"
{
    printf '{"ts":"%s","kind":"ci_triage_verdict","verdict":"real"}\n' "$(hours_ago_ts 1)"
    printf '{"ts":"%s","kind":"ci_triage_verdict","verdict":"known-bug"}\n' "$(hours_ago_ts 1)"
    printf '{"ts":"%s","kind":"ci_triage_verdict","verdict":"real"}\n' "$(hours_ago_ts 1)"
    printf '{"ts":"%s","kind":"ci_triage_verdict","verdict":"flake"}\n' "$(hours_ago_ts 1)"
    printf '{"ts":"%s","kind":"ci_flake_rerun"}\n' "$(hours_ago_ts 1)"
    printf '{"ts":"%s","kind":"duty_officer_action","verdict":"refuted"}\n' "$(hours_ago_ts 1)"
    printf '{"ts":"%s","kind":"duty_officer_action","verdict":"healed"}\n' "$(hours_ago_ts 1)"
    printf '{"ts":"%s","kind":"ci_parity_drift","gate_name":"foo"}\n' "$(hours_ago_ts 1)"
} >> "$AMBIENT"
# accurate=3 (2 real + 1 known-bug), flake=2 (1 verdict + 1 rerun),
# false_positives=1, missed_locally=1. denom=7. score = 3/7*100 = 42.857...
out=$("$SCRIPT" --window-h 24 --json 2>&1)
if echo "$out" | grep -qE '"accurate_failures":3' \
    && echo "$out" | grep -qE '"false_positives":1' \
    && echo "$out" | grep -qE '"missed_locally":1' \
    && echo "$out" | grep -qE '"flake_count":2' \
    && echo "$out" | grep -qE '"score":42\.8'; then
    echo "  PASS"
else
    echo "  FAIL: expected accurate=3 fp=1 missed_locally=1 flake=2 score~42.8, got: $out"
    exit 1
fi

ev_count=$(grep -c '"kind":"ci_qa_accuracy_score"' "$AMBIENT" || true)
if [[ "$ev_count" -lt 1 ]]; then
    echo "  FAIL: expected at least 1 kind=ci_qa_accuracy_score line in ambient, got $ev_count"
    exit 1
fi

# ── Test 4: events outside the window are excluded ───────────────────────────
echo "Test 4: stale events outside window_h are excluded"
> "$AMBIENT"
{
    printf '{"ts":"%s","kind":"ci_triage_verdict","verdict":"real"}\n' "$(hours_ago_ts 1)"
    printf '{"ts":"%s","kind":"ci_triage_verdict","verdict":"real"}\n' "$(hours_ago_ts 48)"
} >> "$AMBIENT"
out=$("$SCRIPT" --window-h 24 --json 2>&1)
if echo "$out" | grep -qE '"accurate_failures":1'; then
    echo "  PASS"
else
    echo "  FAIL: expected accurate_failures=1 (stale event excluded), got: $out"
    exit 1
fi

# ── Test 5: --dry-run does not emit to ambient ───────────────────────────────
echo "Test 5: --dry-run skips ambient emit"
> "$AMBIENT"
printf '{"ts":"%s","kind":"ci_triage_verdict","verdict":"real"}\n' "$(hours_ago_ts 1)" >> "$AMBIENT"
before_lines=$(wc -l < "$AMBIENT")
"$SCRIPT" --window-h 24 --dry-run --json > /dev/null 2>&1
after_lines=$(wc -l < "$AMBIENT")
if [[ "$before_lines" -eq "$after_lines" ]]; then
    echo "  PASS"
else
    echo "  FAIL: --dry-run should not write to ambient.jsonl"
    cat "$AMBIENT"
    exit 1
fi

echo
echo "All 5 ci-qa-accuracy-score smoke tests passed."
