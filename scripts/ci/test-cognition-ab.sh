#!/usr/bin/env bash
# test-cognition-ab.sh — META-045
# Static validation of the cognition-stack A/B experiment harness.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP="$REPO_ROOT/scripts/experiments/cognition-ab-setup.sh"
REPORT="$REPO_ROOT/scripts/experiments/cognition-ab-report.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# ── 1: setup script exists and is executable ─────────────────────────────────
[[ -x "$SETUP" ]] || fail "cognition-ab-setup.sh not found or not executable"
pass "cognition-ab-setup.sh exists and is executable"

# ── 2: report script exists and is executable ────────────────────────────────
[[ -x "$REPORT" ]] || fail "cognition-ab-report.sh not found or not executable"
pass "cognition-ab-report.sh exists and is executable"

# ── 3: setup configures cognition ON for cell A ──────────────────────────────
grep -q 'CHUMP_LESSONS_AT_SPAWN_N=5\|LESSONS_AT_SPAWN_N.*5' "$SETUP" \
    || fail "setup.sh must set CHUMP_LESSONS_AT_SPAWN_N=5 for cell A"
grep -q 'CHUMP_LESSONS_EMBEDDING=1' "$SETUP" \
    || fail "setup.sh must set CHUMP_LESSONS_EMBEDDING=1 for cell A"
pass "cell A configures cognition ON (lessons=5, embedding=1)"

# ── 4: setup configures cognition OFF for cell B ─────────────────────────────
grep -q 'CHUMP_LESSONS_AT_SPAWN_N=0\|LESSONS_AT_SPAWN_N.*0' "$SETUP" \
    || fail "setup.sh must set CHUMP_LESSONS_AT_SPAWN_N=0 for cell B"
pass "cell B configures cognition OFF (lessons=0)"

# ── 5: setup uses separate ambient log per cell ──────────────────────────────
grep -q 'CHUMP_AMBIENT_LOG' "$SETUP" \
    || fail "setup.sh must set CHUMP_AMBIENT_LOG to separate cell logs"
grep -q 'cell-' "$SETUP" \
    || fail "setup.sh ambient log name must include cell identifier"
pass "setup.sh uses separate CHUMP_AMBIENT_LOG per cell"

# ── 6: setup emits cognition_ab_run_start event ──────────────────────────────
grep -q 'cognition_ab_run_start' "$SETUP" \
    || fail "setup.sh must emit cognition_ab_run_start ambient event"
pass "setup.sh emits cognition_ab_run_start event"

# ── 7: setup supports --dry-run flag ─────────────────────────────────────────
grep -q '\-\-dry-run\|DRY_RUN' "$SETUP" \
    || fail "setup.sh must support --dry-run flag for smoke testing"
out=$(bash "$SETUP" --cell A --dry-run 2>&1)
echo "$out" | grep -qi 'dry.run\|would' \
    || fail "--dry-run output must mention dry-run mode"
pass "setup.sh --dry-run works without launching fleet"

# ── 8: report reads session_end events ───────────────────────────────────────
grep -q 'session_end\|outcome.*shipped\|shipped.*outcome' "$REPORT" \
    || fail "report.sh must analyse session_end events with outcome=shipped"
pass "report.sh reads session_end events"

# ── 9: report computes ship rate ─────────────────────────────────────────────
grep -q 'ship_rate\|ship rate' "$REPORT" \
    || fail "report.sh must compute and display ship rate"
pass "report.sh computes ship rate"

# ── 10: report smoke test with fixture data ──────────────────────────────────
TMP=$(mktemp -d -t meta045-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
LOG_A="$TMP/cell-A.jsonl"
LOG_B="$TMP/cell-B.jsonl"

# Write fixture: 8 shipped + 2 abandoned in cell A; 4 shipped + 6 abandoned in cell B
for i in $(seq 1 8); do
    printf '{"kind":"session_end","ts":"2026-05-12T10:0%d:00Z","session_id":"sa-%d","gap_id":"INFRA-%d","outcome":"shipped","elapsed_seconds":3600}\n' "$i" "$i" "$((100+i))" >> "$LOG_A"
done
for i in $(seq 1 2); do
    printf '{"kind":"session_end","ts":"2026-05-12T12:0%d:00Z","session_id":"sa-a%d","gap_id":"INFRA-%d","outcome":"abandoned","elapsed_seconds":600}\n' "$i" "$i" "$((200+i))" >> "$LOG_A"
done
for i in $(seq 1 4); do
    printf '{"kind":"session_end","ts":"2026-05-12T10:0%d:00Z","session_id":"sb-%d","gap_id":"INFRA-%d","outcome":"shipped","elapsed_seconds":5400}\n' "$i" "$i" "$((300+i))" >> "$LOG_B"
done
for i in $(seq 1 6); do
    printf '{"kind":"session_end","ts":"2026-05-12T12:0%d:00Z","session_id":"sb-b%d","gap_id":"INFRA-%d","outcome":"abandoned","elapsed_seconds":900}\n' "$i" "$i" "$((400+i))" >> "$LOG_B"
done

out=$(bash "$REPORT" --log-a "$LOG_A" --log-b "$LOG_B" 2>&1) || true
echo "$out" | grep -qi 'ship rate\|Ship rate' \
    || fail "report.sh smoke test: ship rate not shown in output"
echo "$out" | grep -qi 'cell a\|CELL A\|Cell A' \
    || fail "report.sh smoke test: Cell A not mentioned"
echo "$out" | grep -qi 'cell b\|CELL B\|Cell B' \
    || fail "report.sh smoke test: Cell B not mentioned"
pass "report.sh smoke test: produces comparison table"

# ── 11: cognition_ab_run_start registered in EVENT_REGISTRY ──────────────────
grep -q 'cognition_ab_run_start' "$REGISTRY" \
    || fail "cognition_ab_run_start not registered in EVENT_REGISTRY.yaml"
pass "cognition_ab_run_start registered in EVENT_REGISTRY.yaml"

# ── 12: cognition_ab_comparison registered in EVENT_REGISTRY ─────────────────
grep -q 'cognition_ab_comparison' "$REGISTRY" \
    || fail "cognition_ab_comparison not registered in EVENT_REGISTRY.yaml"
pass "cognition_ab_comparison registered in EVENT_REGISTRY.yaml"

printf '\nAll cognition-ab tests passed.\n'
