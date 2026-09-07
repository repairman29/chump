#!/usr/bin/env bash
# test-node-capacity-plan.sh — unit/logic coverage for the PLACE-half budget formula
# in scripts/ops/node-capacity-plan.sh (RESILIENT-291 Node Fabric #5).
#
# DEPTH: unit/logic (happy-path + edge). Covers compute_worker_budget() across the
# real fleet shapes (CJ orchestration+embed host, cuphead 2-core, big idle build box)
# plus the clamp/disk-brake edges. GAPS (not covered here): live nvidia-smi GPU
# disposition branches, systemctl orchestration-organ detection, and the
# orchestrator's consumption of the plan file — those need a live node (dogfooded on
# CJ + cuphead in the shipping session, not in CI).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHUMP_PLAN_LIB_ONLY=1 source "$HERE/ops/node-capacity-plan.sh"

fail=0
check() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    printf 'ok   — %s (=%s)\n' "$desc" "$got"
  else
    printf 'FAIL — %s: got %s want %s\n' "$desc" "$got" "$want"; fail=1
  fi
}

# args: cores orch_reserve embed_reserve disk_pct [headroom]
check "CJ (4c orch+embed, disk89) -> 1"      "$(compute_worker_budget 4 1 1 89)"  1
check "cuphead (2c clean, disk96) -> 1"      "$(compute_worker_budget 2 0 0 96)"  1
check "big idle build box (16c, disk40) ->12" "$(compute_worker_budget 16 0 0 40)" 12
check "8c orchestration host -> 5"           "$(compute_worker_budget 8 1 0 50)"  5
check "4c clean node -> 3"                    "$(compute_worker_budget 4 0 0 50)"  3
check "1c tiny node -> 1 (never 0)"          "$(compute_worker_budget 1 0 0 10)"  1
check "2c orch+embed reserves both -> 1"     "$(compute_worker_budget 2 1 1 50)"  1
check "disk-brake pins a big box to 1"       "$(compute_worker_budget 16 0 0 95)" 1
check "reserves never underflow below 1"     "$(compute_worker_budget 3 2 2 50)"  1
check "budget never exceeds cores-1"         "$(compute_worker_budget 4 0 0 50 100)" 3
check "headroom override (8c, 50%) -> 4"     "$(compute_worker_budget 8 0 0 50 50)"  4

if [ "$fail" -ne 0 ]; then echo "node-capacity-plan formula: FAILURES"; exit 1; fi
echo "node-capacity-plan formula: all cases pass"
