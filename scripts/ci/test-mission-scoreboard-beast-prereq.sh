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

if [[ "$fail" -eq 0 ]]; then
  echo "[test-mission-scoreboard-beast-prereq] PASS"
else
  echo "[test-mission-scoreboard-beast-prereq] FAIL"
  exit 1
fi
