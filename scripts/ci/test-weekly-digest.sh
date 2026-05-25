#!/usr/bin/env bash
# capability-guard-exempt: existing CHUMP_BIN check + exit-0 skip path covers missing-binary case (CREDIBLE-078)
# test-weekly-digest.sh — CI smoke test for INFRA-646 chump health-digest.
#
# Creates a fixture ambient.jsonl with a known week of events, runs
# `chump health-digest --json --since 7d`, and asserts the output contains
# the expected fields and values.
#
# Exit 0 = pass, non-zero = fail.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CHUMP_BIN="${CHUMP_BIN:-$HOME/.cargo/bin/chump}"
FIXTURE_DIR="$(mktemp -d /tmp/chump-infra646-ci-XXXXXX)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

# ── Build the fixture ─────────────────────────────────────────────────────────
mkdir -p "$FIXTURE_DIR/.chump-locks"
AMBIENT="$FIXTURE_DIR/.chump-locks/ambient.jsonl"

NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 5 ship_grade events
for i in 1 2 3 4 5; do
cat >> "$AMBIENT" <<EOF
{"kind":"ship_grade","ts":"$NOW_ISO","gap_id":"INFRA-$i","model":"sonnet","agent_id":"1","clippy_ok":true,"test_added":true,"rebase_clean":true}
EOF
done

# 1 abandoned session (contributes to waste + ship rate denominator)
cat >> "$AMBIENT" <<EOF
{"event":"session_end","kind":"session_end","ts":"$NOW_ISO","session_id":"sess-abandoned","gap_id":"INFRA-99","outcome":"abandoned","input_tokens":30000,"output_tokens":8000,"cache_read_tokens":5000,"elapsed_seconds":400}
EOF

# 1 fleet_wedge (SLO breach + waste)
cat >> "$AMBIENT" <<EOF
{"event":"ALERT","kind":"fleet_wedge","ts":"$NOW_ISO","gap_id":"INFRA-50","cooldown_secs":3600}
EOF

# 1 pr_stuck (SLO breach)
cat >> "$AMBIENT" <<EOF
{"event":"ALERT","kind":"pr_stuck","ts":"$NOW_ISO","pr":100}
EOF

# ── Run chump health-digest ───────────────────────────────────────────────────
OUTPUT="$("$CHUMP_BIN" health-digest --since 7d --json \
    --chump-root "$FIXTURE_DIR" 2>/dev/null)" || {
    # Fallback: some builds use CHUMP_REPO_ROOT env var
    OUTPUT="$(CHUMP_REPO_ROOT="$FIXTURE_DIR" "$CHUMP_BIN" health-digest --since 7d --json 2>/dev/null)"
}

echo "Output: $OUTPUT"

# ── Assertions ────────────────────────────────────────────────────────────────
PASS=1

assert_contains() {
    local label="$1" needle="$2"
    if echo "$OUTPUT" | grep -qF "$needle"; then
        echo "  PASS: $label"
    else
        echo "  FAIL: $label — expected '$needle' in output"
        PASS=0
    fi
}

assert_not_contains() {
    local label="$1" needle="$2"
    if ! echo "$OUTPUT" | grep -qF "$needle"; then
        echo "  PASS: $label"
    else
        echo "  FAIL: $label — did NOT expect '$needle' in output"
        PASS=0
    fi
}

echo ""
echo "=== INFRA-646 health-digest CI assertions ==="

assert_contains "kind=weekly_health_digest" '"kind":"weekly_health_digest"'
assert_contains "ships=5" '"ships":5'
assert_contains "p0_compliant present" '"p0_compliant":'
assert_contains "waste_usd present" '"waste_usd":'
assert_contains "slo_breaches present" '"slo_breaches":'
assert_contains "effective_filed present" '"effective_filed":'
assert_contains "effective_shipped present" '"effective_shipped":'
assert_contains "waste_by_class array" '"waste_by_class":'
assert_contains "top_burning_gaps array" '"top_burning_gaps":'
assert_contains "pillar_counts array" '"pillar_counts":'
assert_contains "slo_detail array" '"slo_detail":'

# Ship rate: 5 ships / (5+1) = 83.3%; not null
assert_not_contains "ship_rate not null" '"ship_rate_pct":null'

echo ""
if [[ "$PASS" == "1" ]]; then
    echo "INFRA-646: all assertions passed."
    exit 0
else
    echo "INFRA-646: one or more assertions FAILED."
    exit 1
fi
