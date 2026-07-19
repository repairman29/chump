#!/usr/bin/env bash
# scripts/ci/test-bot-merge-heartbeat.sh — INFRA-2455
#
# bot-merge.sh must surface a LIVE stderr liveness heartbeat (not only a health
# FILE) so a slow-but-working run (e.g. a multi-minute cold preflight) isn't
# mistaken for a hang. Root cause (VOA-002, 2026-06-02): the first
# operator-visible stderr signal was the 50%-budget warn (~450s); an operator
# killed bot-merge at 420s believing it stalled when it was mid-preflight,
# which trained a manual-bypass reflex. The fix reuses the existing 30s health
# loop + step file + per-step gtimeout/budget-warn — no new event kind.

set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 2
BM=scripts/coord/bot-merge.sh
P=0; F=0
p(){ echo "[PASS] $1"; P=$((P+1)); }
f(){ echo "[FAIL] $1"; F=$((F+1)); }

echo "=== test-bot-merge-heartbeat.sh (INFRA-2455) ==="

[[ -f "$BM" ]] || { f "bot-merge.sh MISSING"; echo "=== $P passed, $((F)) failed ==="; exit 1; }
p "bot-merge.sh present"
bash -n "$BM" 2>/dev/null && p "bot-merge.sh parses (bash -n)" || f "bot-merge.sh SYNTAX ERROR"

grep -q 'INFRA-2455' "$BM" 2>/dev/null \
  && p "INFRA-2455 heartbeat change present" || f "INFRA-2455 marker absent"
grep -q 'CHUMP_BOT_MERGE_HEARTBEAT_S' "$BM" 2>/dev/null \
  && p "interval tunable via CHUMP_BOT_MERGE_HEARTBEAT_S" || f "interval not tunable"
{ grep -q '_hb_elapsed' "$BM" && grep -q '_hb_interval' "$BM"; } 2>/dev/null \
  && p "elapsed + interval counters present" || f "elapsed/interval counters missing"

# The heartbeat subshell (from the elapsed counter init to the PID capture) must
# route liveness to stderr (>&2), not only to the health file.
if awk '/_hb_elapsed=0/,/_BM_HEALTH_PID=/' "$BM" | grep -q '>&2'; then
  p "heartbeat routes liveness to stderr (>&2)"
else
  f "heartbeat does not write to stderr"
fi

# Must reuse the existing step file (no parallel tracking surface).
# INFRA-1732: step file now carries a 2nd line (step_started_at) so reads
# use sed -n '1p' instead of a bare `cat` — still the same file, no new surface.
grep -q 'step="\$(sed -n .1p. "\$sf"' "$BM" 2>/dev/null \
  && p "reuses the existing step file" || f "does not reuse the step file"

# Non-duplication (META-063): stall detection stays on the existing
# bot_merge_step_stalled / bot_merge_budget_warn — no redundant new kind.
if grep -q 'bot_merge_phase_slow' "$BM" 2>/dev/null; then
  f "introduced a redundant bot_merge_phase_slow kind (reuse step_stalled/budget_warn)"
else
  p "no redundant stall event kind (reuses step_stalled/budget_warn)"
fi

echo ""
echo "=== $P passed, $F failed ==="
[[ "$F" -eq 0 ]] || exit 1
