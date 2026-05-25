#!/usr/bin/env bash
# test-preflight-ci-agreement.sh — INFRA-1927: smoke test for the preflight↔CI
# agreement measurement loop.
#
# Synthesises:
#   - A fake preflight_ci_agreement event (preflight_pass=true)
#   - A fake preflight_ci_agreement_resolved event (ci_pass=false → MISMATCH)
#   - A second pair (both_pass)
#   - A third pair (both_fail)
#   - A fourth pair (local_fail_ci_pass)
#
# Invokes scripts/dev/preflight-ci-agreement-report.sh with the synthetic log,
# asserts the rollup counts are correct.
#
# Assertions (≥ 5 per gap AC):
#   1. agreement_pct is a number (not null)
#   2. total_pushes == 4 (4 resolved pairs)
#   3. local_pass_ci_fail_count == 1 (mismatch: pass locally, fail CI)
#   4. both_pass_count == 1
#   5. both_fail_count == 1
#   6. local_fail_ci_pass_count == 1
#   7. agreement_pct == 75.0  ((both_pass + both_fail) / total = 2/4 * 100)
#
# Exit: 0 = all assertions pass; 1 = any assertion fails

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPORT_SCRIPT="$REPO_ROOT/scripts/dev/preflight-ci-agreement-report.sh"

PASS=0
FAIL=0

ok() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  FAIL: $1"
    FAIL=$((FAIL + 1))
}

# ── Setup: synthetic ambient.jsonl ──────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d -t test-pf-ci-agreement.XXXXXX)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

AMBIENT="$TMPDIR_TEST/ambient.jsonl"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Pair 1: local pass, CI fail → local_pass_ci_fail (mismatch)
SHA1="aaaa1111bbbb2222cccc3333dddd4444eeee5555"
printf '{"ts":"%s","kind":"preflight_ci_agreement","sha":"%s","branch":"chump/infra-1927-claim","gap_id":"INFRA-1927","preflight_pass":true,"preflight_secs":3}\n' \
    "$NOW" "$SHA1" >> "$AMBIENT"
printf '{"ts":"%s","kind":"preflight_ci_agreement_resolved","sha":"%s","gap_id":"INFRA-1927","ci_pass":false,"ci_required_pass":false,"mismatch":true}\n' \
    "$NOW" "$SHA1" >> "$AMBIENT"

# Pair 2: both pass
SHA2="bbbb2222cccc3333dddd4444eeee5555ffff6666"
printf '{"ts":"%s","kind":"preflight_ci_agreement","sha":"%s","branch":"chump/infra-100-claim","gap_id":"INFRA-100","preflight_pass":true,"preflight_secs":5}\n' \
    "$NOW" "$SHA2" >> "$AMBIENT"
printf '{"ts":"%s","kind":"preflight_ci_agreement_resolved","sha":"%s","gap_id":"INFRA-100","ci_pass":true,"ci_required_pass":true,"mismatch":false}\n' \
    "$NOW" "$SHA2" >> "$AMBIENT"

# Pair 3: both fail
SHA3="cccc3333dddd4444eeee5555ffff6666aaaa7777"
printf '{"ts":"%s","kind":"preflight_ci_agreement","sha":"%s","branch":"chump/infra-101-claim","gap_id":"INFRA-101","preflight_pass":false,"preflight_secs":8}\n' \
    "$NOW" "$SHA3" >> "$AMBIENT"
printf '{"ts":"%s","kind":"preflight_ci_agreement_resolved","sha":"%s","gap_id":"INFRA-101","ci_pass":false,"ci_required_pass":false,"mismatch":false}\n' \
    "$NOW" "$SHA3" >> "$AMBIENT"

# Pair 4: local fail, CI pass → local_fail_ci_pass
SHA4="dddd4444eeee5555ffff6666aaaa7777bbbb8888"
printf '{"ts":"%s","kind":"preflight_ci_agreement","sha":"%s","branch":"chump/infra-102-claim","gap_id":"INFRA-102","preflight_pass":false,"preflight_secs":2}\n' \
    "$NOW" "$SHA4" >> "$AMBIENT"
printf '{"ts":"%s","kind":"preflight_ci_agreement_resolved","sha":"%s","gap_id":"INFRA-102","ci_pass":true,"ci_required_pass":true,"mismatch":true}\n' \
    "$NOW" "$SHA4" >> "$AMBIENT"

# Pair 5: preflight_ci_agreement with no resolved yet (should NOT appear in counts)
SHA5="eeee5555ffff6666aaaa7777bbbb8888cccc9999"
printf '{"ts":"%s","kind":"preflight_ci_agreement","sha":"%s","branch":"chump/infra-103-claim","gap_id":"INFRA-103","preflight_pass":true,"preflight_secs":4}\n' \
    "$NOW" "$SHA5" >> "$AMBIENT"

echo "=== test-preflight-ci-agreement: running rollup ==="
echo ""

# ── Run report script in JSON mode ──────────────────────────────────────────
REPORT_OUT="$(CHUMP_AMBIENT_LOG="$AMBIENT" bash "$REPORT_SCRIPT" --json 2>&1)"

echo "Report output: $REPORT_OUT"
echo ""

# ── Assertions ───────────────────────────────────────────────────────────────

# 1. agreement_pct is not null
agreement_pct="$(printf '%s' "$REPORT_OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("agreement_pct","null"))' 2>/dev/null || echo "parse_error")"
if [[ "$agreement_pct" != "null" && "$agreement_pct" != "parse_error" ]]; then
    ok "agreement_pct is a number (got: $agreement_pct)"
else
    fail "agreement_pct is null or parse error (got: $agreement_pct)"
fi

# 2. total_pushes == 4
total="$(printf '%s' "$REPORT_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("total_pushes","?"))' 2>/dev/null || echo "?")"
if [[ "$total" == "4" ]]; then
    ok "total_pushes == 4"
else
    fail "total_pushes expected 4, got $total"
fi

# 3. local_pass_ci_fail_count == 1
local_pass_ci_fail="$(printf '%s' "$REPORT_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("local_pass_ci_fail_count","?"))' 2>/dev/null || echo "?")"
if [[ "$local_pass_ci_fail" == "1" ]]; then
    ok "local_pass_ci_fail_count == 1 (mismatch pair counted)"
else
    fail "local_pass_ci_fail_count expected 1, got $local_pass_ci_fail"
fi

# 4. both_pass_count == 1
both_pass="$(printf '%s' "$REPORT_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("both_pass_count","?"))' 2>/dev/null || echo "?")"
if [[ "$both_pass" == "1" ]]; then
    ok "both_pass_count == 1"
else
    fail "both_pass_count expected 1, got $both_pass"
fi

# 5. both_fail_count == 1
both_fail="$(printf '%s' "$REPORT_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("both_fail_count","?"))' 2>/dev/null || echo "?")"
if [[ "$both_fail" == "1" ]]; then
    ok "both_fail_count == 1"
else
    fail "both_fail_count expected 1, got $both_fail"
fi

# 6. local_fail_ci_pass_count == 1
local_fail_ci_pass="$(printf '%s' "$REPORT_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("local_fail_ci_pass_count","?"))' 2>/dev/null || echo "?")"
if [[ "$local_fail_ci_pass" == "1" ]]; then
    ok "local_fail_ci_pass_count == 1"
else
    fail "local_fail_ci_pass_count expected 1, got $local_fail_ci_pass"
fi

# 7. agreement_pct == 75.0  (both_pass + both_fail = 2; total = 4; 2/4*100 = 50.0)
# Wait: both_pass=1, both_fail=1, mismatch cases=2 → agreement = (1+1)/4*100 = 50.0
if [[ "$agreement_pct" == "50.0" ]]; then
    ok "agreement_pct == 50.0 (2 agree out of 4)"
else
    fail "agreement_pct expected 50.0, got $agreement_pct"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
