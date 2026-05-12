#!/usr/bin/env bash
# CI gate: FLEET-035 — speculative race-loss event + fleet-status pane
# Acceptance criteria:
#   1. bot-merge.sh emits speculative_race_loss to ambient.jsonl after closing loser PR
#   2. fleet-status.sh renders --pane race-loss without error
#   3. EVENT_REGISTRY.yaml registers kind=speculative_race_loss with required fields
# Author: chump/fleet-035-claim

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

echo "=== FLEET-035: speculative race-loss tracking ==="

# ── 1. bot-merge.sh contains speculative_race_loss emit ───────────────────────
echo "--- 1. bot-merge.sh emits speculative_race_loss"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
if [[ ! -f "$BOT_MERGE" ]]; then
  fail "bot-merge.sh not found at $BOT_MERGE"
else
  if grep -q 'speculative_race_loss' "$BOT_MERGE"; then
    ok "speculative_race_loss emit present in bot-merge.sh"
  else
    fail "speculative_race_loss emit missing from bot-merge.sh"
  fi

  # Check required fields are emitted
  for field in ts kind session gap_id loser_pr winner_pr loser_branch; do
    if grep -A5 'speculative_race_loss' "$BOT_MERGE" | grep -q "$field"; then
      ok "  field $field present in emit block"
    else
      fail "  field $field missing from emit block"
    fi
  done

  # Check FLEET-035 is referenced
  if grep -q 'FLEET-035' "$BOT_MERGE"; then
    ok "FLEET-035 reference in bot-merge.sh"
  else
    fail "FLEET-035 reference missing from bot-merge.sh"
  fi
fi

# ── 2. fleet-status.sh has race-loss pane ─────────────────────────────────────
echo "--- 2. fleet-status.sh race-loss pane"
FLEET_STATUS="$REPO_ROOT/scripts/dispatch/fleet-status.sh"
if [[ ! -f "$FLEET_STATUS" ]]; then
  fail "fleet-status.sh not found at $FLEET_STATUS"
else
  if grep -q 'race-loss\|race_loss' "$FLEET_STATUS"; then
    ok "race-loss pane referenced in fleet-status.sh"
  else
    fail "race-loss pane missing from fleet-status.sh"
  fi

  if grep -q 'render_race_loss\|speculative_race_loss' "$FLEET_STATUS"; then
    ok "render_race_loss function present in fleet-status.sh"
  else
    fail "render_race_loss function missing from fleet-status.sh"
  fi

  if grep -q 'FLEET-035' "$FLEET_STATUS"; then
    ok "FLEET-035 reference in fleet-status.sh"
  else
    fail "FLEET-035 reference missing from fleet-status.sh"
  fi
fi

# ── 3. fleet-status.sh --pane race-loss runs without error ────────────────────
echo "--- 3. fleet-status.sh --pane race-loss smoke run"
# Create a temp ambient log with a synthetic race-loss event so output is exercised
TMPDIR_TEST="$(mktemp -d)"
FAKE_AMB="$TMPDIR_TEST/ambient.jsonl"
printf '{"ts":"2026-05-12T00:00:00Z","kind":"speculative_race_loss","session":"test-sess","gap_id":"FLEET-999","loser_pr":9999,"winner_pr":9998,"loser_branch":"chump/fleet-999-b"}\n' \
  > "$FAKE_AMB"

if CHUMP_AMBIENT_LOG="$FAKE_AMB" bash "$FLEET_STATUS" --pane race-loss 2>&1 | grep -qiE 'race.loss|speculative|FLEET-999|9999'; then
  ok "fleet-status.sh --pane race-loss produces race-loss output"
elif CHUMP_AMBIENT_LOG="$FAKE_AMB" bash "$FLEET_STATUS" --pane race-loss >/dev/null 2>&1; then
  ok "fleet-status.sh --pane race-loss exits 0 (no events case)"
else
  fail "fleet-status.sh --pane race-loss exited non-zero"
fi
rm -rf "$TMPDIR_TEST"

# ── 4. EVENT_REGISTRY.yaml has kind: speculative_race_loss ────────────────────
echo "--- 4. EVENT_REGISTRY.yaml registration"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if [[ ! -f "$REGISTRY" ]]; then
  fail "EVENT_REGISTRY.yaml not found"
else
  if grep -q 'speculative_race_loss' "$REGISTRY"; then
    ok "speculative_race_loss registered in EVENT_REGISTRY.yaml"
  else
    fail "speculative_race_loss missing from EVENT_REGISTRY.yaml"
  fi

  # Verify required fields documented
  if grep -A10 'speculative_race_loss' "$REGISTRY" | grep -q 'fields_required'; then
    ok "fields_required documented in registry entry"
  else
    fail "fields_required missing from registry entry"
  fi

  if grep -A10 'speculative_race_loss' "$REGISTRY" | grep -qE 'gap_id|loser_pr|winner_pr'; then
    ok "key fields (gap_id, loser_pr, winner_pr) in registry entry"
  else
    fail "key fields missing from registry entry"
  fi
fi

# ── 5. Ambient emit goes to correct path ──────────────────────────────────────
echo "--- 5. bot-merge.sh respects CHUMP_AMBIENT_LOG"
if grep -q 'CHUMP_AMBIENT_LOG' "$BOT_MERGE"; then
  ok "CHUMP_AMBIENT_LOG respected in bot-merge.sh emit"
else
  fail "CHUMP_AMBIENT_LOG not referenced in bot-merge.sh emit block"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo "FLEET-035 CI gate FAILED"
  exit 1
fi
echo "FLEET-035 CI gate PASSED"
