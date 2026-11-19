#!/usr/bin/env bash
# test-mission-scoreboard-beast-prereq.sh — MISSION-066.
#
# Proves mission-scoreboard.sh's new ⑤ section surfaces whether the
# MISSION-019..024 BEAST-MODE prerequisite slice is stuck (0 implementation
# commits) because CHUMP_EXTERNAL_REPO_PICK_OK is closed — the picker gate
# in crates/chump-coord/src/worker/capability.rs (INFRA-2113) that makes
# standard fleet workers skip external_repo:-tagged gaps. Without this
# section the stall was invisible (eyeballed, never measured).
#
# Depth: presence + gate-state correctness. Hermetic-ish: real repo/state.db
# (matches test-mission-scoreboard-modes.sh convention), but assertions only
# depend on the CHUMP_EXTERNAL_REPO_PICK_OK env var, not on live gap counts
# — so the test is stable as the queue drains.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/dev/mission-scoreboard.sh"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"

[[ -x "$SCRIPT" ]] || { echo "[test] FAIL: scoreboard not executable"; exit 1; }

fail=0

# ── (a) section header present in default mode ──────────────────────────
out=$(CHUMP_EXTERNAL_REPO_PICK_OK= "$SCRIPT" 2>&1 || true)
echo "$out" | grep -q '⑤ BEAST-MODE prerequisite readiness' \
  || { echo "[test] FAIL: (a) missing ⑤ BEAST-MODE prerequisite readiness section"; fail=1; }

# ── (b) gate reported closed when CHUMP_EXTERNAL_REPO_PICK_OK is unset ──
out=$(env -u CHUMP_EXTERNAL_REPO_PICK_OK "$SCRIPT" 2>&1 || true)
echo "$out" | grep -q 'pick-gate=closed' \
  || { echo "[test] FAIL: (b) expected pick-gate=closed when env unset"; fail=1; }

# ── (c) gate reported open when CHUMP_EXTERNAL_REPO_PICK_OK=1 ───────────
out=$(CHUMP_EXTERNAL_REPO_PICK_OK=1 "$SCRIPT" 2>&1 || true)
echo "$out" | grep -q 'pick-gate=open' \
  || { echo "[test] FAIL: (c) expected pick-gate=open when CHUMP_EXTERNAL_REPO_PICK_OK=1"; fail=1; }

# ── (d) ambient event emitted for KPI/history consumers ─────────────────
before=$(wc -l < "$AMBIENT" 2>/dev/null || echo 0)
"$SCRIPT" >/dev/null 2>&1 || true
after=$(wc -l < "$AMBIENT" 2>/dev/null || echo 0)
if [[ "$after" -le "$before" ]]; then
  echo "[test] FAIL: (d) ambient.jsonl did not grow after scoreboard run"; fail=1
else
  tail -n $((after - before)) "$AMBIENT" | grep -q '"kind":"beast_prereq_check"' \
    || { echo "[test] FAIL: (d) no beast_prereq_check event in new ambient lines"; fail=1; }
fi

# ── (e)/(f) consecutive-cycle stall streak (MISSION-066 refile) ─────────
# Previously the "Nth consecutive cycle" claim in gap titles was eyeballed,
# not derived. Seed synthetic history into ambient.jsonl (backed up +
# restored via trap so we don't pollute the real stream) and verify the
# streak counter accumulates across runs and an escalation line fires once
# the streak crosses the threshold. This block fails against the
# pre-MISSION-066-refile script because "streak" never appears in its
# output or its beast_prereq_check JSON at all.
backup=""
if [[ -f "$AMBIENT" ]]; then
  backup="$(mktemp)"
  cp "$AMBIENT" "$backup"
fi
restore_ambient() {
  if [[ -n "$backup" ]]; then
    mv "$backup" "$AMBIENT"
  else
    rm -f "$AMBIENT"
  fi
}
trap restore_ambient EXIT

out=$("$SCRIPT" 2>&1 || true)
echo "$out" | grep -qE 'streak: [0-9]+ consecutive' \
  || { echo "[test] FAIL: (e) missing streak readout in ⑤ section"; fail=1; }
tail -1 "$AMBIENT" 2>/dev/null | grep -qE '"streak":[0-9]+' \
  || { echo "[test] FAIL: (e) beast_prereq_check event missing streak field"; fail=1; }

if echo "$out" | grep -q 'zero-commit=0 '; then
  # Queue currently drained of stuck prerequisites — streak must be 0, no escalation.
  echo "$out" | grep -q 'streak: 0 consecutive' \
    || { echo "[test] FAIL: (e) expected streak: 0 when zero-commit=0"; fail=1; }
  echo "$out" | grep -q 'ESCALATION' \
    && { echo "[test] FAIL: (e) escalation fired with zero-commit=0"; fail=1; }
else
  # Queue currently has stuck prerequisites — seed 9 synthetic prior cycles
  # (all zero_commit>0) so this run's streak crosses the >=10 threshold.
  mkdir -p "$(dirname "$AMBIENT")"
  i=0
  while [[ "$i" -lt 9 ]]; do
    printf '{"ts":"1970-01-01T00:00:00Z","kind":"beast_prereq_check","open":1,"zero_commit":1,"pick_gate":"closed","streak":%d}\n' "$((i+1))" >> "$AMBIENT"
    i=$((i+1))
  done
  out2=$("$SCRIPT" 2>&1 || true)
  echo "$out2" | grep -qE 'streak: (1[0-9]|[2-9][0-9]+) consecutive' \
    || { echo "[test] FAIL: (f) expected streak >= 10 after seeding 9 prior stalled cycles"; fail=1; }
  echo "$out2" | grep -q '🚨 ESCALATION' \
    || { echo "[test] FAIL: (f) expected escalation line once streak >= 10"; fail=1; }

  # A zero_commit=0 sentinel in history must reset the streak, not extend it.
  printf '{"ts":"1970-01-01T00:00:01Z","kind":"beast_prereq_check","open":1,"zero_commit":0,"pick_gate":"closed","streak":0}\n' >> "$AMBIENT"
  out3=$("$SCRIPT" 2>&1 || true)
  echo "$out3" | grep -qE 'streak: 1 consecutive' \
    || { echo "[test] FAIL: (f) expected streak to reset to 1 after a zero_commit=0 sentinel"; fail=1; }
fi

if [[ "$fail" -eq 0 ]]; then
  echo "[test-mission-scoreboard-beast-prereq] PASS"
else
  echo "[test-mission-scoreboard-beast-prereq] FAIL"
  exit 1
fi
