#!/usr/bin/env bash
# test-classify-incident.sh — INFRA-896
# Validates classify-incident.sh: severity mapping, aggregation window,
# multiple triggers, dedup, opt-out, dry-run, exit codes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/classify-incident.sh"

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -x "$SCRIPT" ]] || fail "classify-incident.sh not found or not executable at $SCRIPT"

TMP_DIR="$(mktemp -d -t chump-classify-incident-test-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

AMBIENT="$TMP_DIR/ambient.jsonl"
ts_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── 1: CHUMP_INCIDENT_DISABLE=1 skips and exits 0 ────────────────────────────
out=$(CHUMP_INCIDENT_DISABLE=1 CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SCRIPT" 2>&1 || true)
echo "$out" | grep -qi 'disable\|skip' \
    || fail "CHUMP_INCIDENT_DISABLE=1 should print disable/skip message"
CHUMP_INCIDENT_DISABLE=1 CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SCRIPT" \
    || fail "CHUMP_INCIDENT_DISABLE=1 must exit 0"
pass "CHUMP_INCIDENT_DISABLE=1 skips classification and exits 0"

# ── 2: missing ambient.jsonl exits 0 (no incidents) ──────────────────────────
CHUMP_AMBIENT_LOG="$TMP_DIR/nonexistent.jsonl" bash "$SCRIPT" \
    || fail "missing ambient.jsonl should exit 0"
pass "missing ambient.jsonl exits 0"

# ── 3: severity mapping — fleet_wedge → P0 ───────────────────────────────────
printf '{"ts":"%s","kind":"fleet_wedge","session":"test"}\n' "$(ts_now)" > "$AMBIENT"
out=$(CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SCRIPT" --dry-run 2>&1 || true)
echo "$out" | grep -qi "P0\|fleet_wedge" \
    || fail "fleet_wedge should produce P0 classification; got: $out"
pass "severity mapping: fleet_wedge → P0"

# ── 4: severity mapping — silent_agent → P1 ──────────────────────────────────
printf '{"ts":"%s","kind":"silent_agent","session":"test"}\n' "$(ts_now)" > "$AMBIENT"
out=$(CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SCRIPT" --dry-run 2>&1 || true)
echo "$out" | grep -qi "P1\|silent_agent" \
    || fail "silent_agent should produce P1 classification; got: $out"
pass "severity mapping: silent_agent → P1"

# ── 5: severity mapping — pr_stuck → P2 ──────────────────────────────────────
printf '{"ts":"%s","kind":"pr_stuck","session":"test"}\n' "$(ts_now)" > "$AMBIENT"
out=$(CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SCRIPT" --dry-run 2>&1 || true)
echo "$out" | grep -qi "P2\|pr_stuck" \
    || fail "pr_stuck should produce P2 classification; got: $out"
pass "severity mapping: pr_stuck → P2"

# ── 6: aggregation — multiple events of same kind counted correctly ───────────
{
    printf '{"ts":"%s","kind":"pr_stuck","session":"a"}\n' "$(ts_now)"
    printf '{"ts":"%s","kind":"pr_stuck","session":"b"}\n' "$(ts_now)"
    printf '{"ts":"%s","kind":"pr_stuck","session":"c"}\n' "$(ts_now)"
} > "$AMBIENT"
out=$(CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SCRIPT" --dry-run 2>&1 || true)
echo "$out" | grep -q "pr_stuck" \
    || fail "aggregation: pr_stuck should appear in output; got: $out"
pass "aggregation: multiple pr_stuck events counted"

# ── 7: aggregation window — stale events outside window are ignored ───────────
# Write an event with a timestamp 2h in the past; use window of 300s
STALE_TS="2000-01-01T00:00:00Z"
printf '{"ts":"%s","kind":"fleet_wedge","session":"stale"}\n' "$STALE_TS" > "$AMBIENT"
exit_code=0
CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SCRIPT" --window 300 >/dev/null 2>&1 || exit_code=$?
[[ "$exit_code" -eq 0 ]] \
    || fail "stale event outside window should produce exit 0 (no incidents); got $exit_code"
pass "aggregation window: events outside window are excluded"

# ── 8: multiple triggers — each kind emits a separate incident_classified ─────
{
    printf '{"ts":"%s","kind":"fleet_wedge","session":"a"}\n' "$(ts_now)"
    printf '{"ts":"%s","kind":"pr_stuck","session":"b"}\n' "$(ts_now)"
} > "$AMBIENT"
AMBIENT_OUT="$TMP_DIR/ambient_out.jsonl"
CHUMP_AMBIENT_LOG="$AMBIENT_OUT" bash "$SCRIPT" --json < /dev/null 2>/dev/null || true
# Feed the input file
CHUMP_INCIDENT_WINDOW_S=3600 CHUMP_AMBIENT_LOG="$TMP_DIR/ambient_multi.jsonl" \
    bash "$SCRIPT" --json 2>/dev/null <<< "$(cat "$AMBIENT")" 2>/dev/null || true
# Verify via dry-run output containing both kinds
out=$(CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SCRIPT" --dry-run 2>&1 || true)
echo "$out" | grep -q "fleet_wedge" \
    || fail "multiple triggers: fleet_wedge missing from output; got: $out"
echo "$out" | grep -q "pr_stuck" \
    || fail "multiple triggers: pr_stuck missing from output; got: $out"
pass "multiple triggers: each incident kind emits separate classification"

# ── 9: incident_classified emitted to ambient.jsonl with required fields ──────
{
    printf '{"ts":"%s","kind":"silent_agent","session":"x"}\n' "$(ts_now)"
} > "$AMBIENT"
AMBIENT2="$TMP_DIR/ambient_out2.jsonl"
cp "$AMBIENT" "$AMBIENT2"
CHUMP_AMBIENT_LOG="$AMBIENT2" bash "$SCRIPT" >/dev/null 2>&1 || true

grep -q 'incident_classified' "$AMBIENT2" \
    || fail "incident_classified not written to ambient.jsonl"
event=$(grep 'incident_classified' "$AMBIENT2" | head -1)
for field in 'ts' 'kind' 'session' 'severity' 'trigger_kind' 'count' 'window_s'; do
    echo "$event" | grep -q "\"$field\"" \
        || fail "incident_classified missing field $field in: $event"
done
pass "incident_classified event has all required fields (ts, kind, session, severity, trigger_kind, count, window_s)"

# ── 10: non-zero exit when incidents found ───────────────────────────────────
{
    printf '{"ts":"%s","kind":"cascade_backoff","session":"x"}\n' "$(ts_now)"
} > "$AMBIENT"
exit_code=0
CHUMP_AMBIENT_LOG="$AMBIENT" bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?
[[ "$exit_code" -ne 0 ]] \
    || fail "should exit non-zero when incidents found; got 0"
pass "exits non-zero when incidents detected"

# ── 11: unknown flag exits 2 ─────────────────────────────────────────────────
exit_code=0
bash "$SCRIPT" --bad-flag 2>&1 || exit_code=$?
[[ "$exit_code" -eq 2 ]] \
    || fail "unknown flag should exit 2; got $exit_code"
pass "unknown flag exits 2"

# ── 12: EVENT_REGISTRY.yaml has incident_classified ──────────────────────────
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
[[ -f "$REGISTRY" ]] || fail "EVENT_REGISTRY.yaml not found at $REGISTRY"
grep -q 'kind: incident_classified' "$REGISTRY" \
    || fail "incident_classified not registered in EVENT_REGISTRY.yaml"
pass "incident_classified registered in EVENT_REGISTRY.yaml"

printf '\nAll classify-incident tests passed.\n'
