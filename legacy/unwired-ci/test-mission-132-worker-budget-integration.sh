#!/usr/bin/env bash
# scripts/ci/test-mission-132-worker-budget-integration.sh — MISSION-132
#
# Proves the live-sizing pipeline is actually wired end-to-end, not just that
# compute_worker_budget() is a correct pure function (scripts/ci/test-node-capacity-plan.sh
# already covers that) and not just that node-orchestrator.sh HAS an effective_max()
# function (test-node-orchestrator-max-throttle.sh covers that in isolation):
#
#   AC1. node-capacity-plan.sh's plan() calls compute_worker_budget() and the result
#        lands in plan.json's budget.worker_budget — then node-orchestrator.sh's
#        effective_max() (the function enforce_cap()/scale()/cargo_jobs_cap() all
#        size workers from) reads THAT value via plan_worker_budget(), not a blind
#        cores-1 fallback.
#   AC3. A node with limited resources (orchestration host + CPU-bound embed host,
#        both competing for cores) receives a REDUCED worker budget relative to the
#        same hardware with no reserves — proving the allocation pipeline is
#        resource-aware end to end, from live signals through to the enforced cap.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLANNER="$REPO_ROOT/scripts/ops/node-capacity-plan.sh"
ORCH="$REPO_ROOT/scripts/ops/node-orchestrator.sh"

[[ -f "$PLANNER" ]] || { echo "[FAIL] $PLANNER not found"; exit 1; }
[[ -f "$ORCH" ]] || { echo "[FAIL] $ORCH not found"; exit 1; }

echo "=== MISSION-132: live sizing wired into resource allocation pipeline ==="

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

FAKE_BIN="$TMPDIR_TEST/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/sudo" <<'EOS'
#!/usr/bin/env bash
exec "$@"
EOS
chmod +x "$FAKE_BIN/sudo"

# run_plan_for_node MODE -> writes plan.json for a simulated 4-core node, returns its path.
#   MODE=constrained: 3 orchestration organs active + ollama running (CPU-bound,
#                      no GPU) -> orch_reserve=1, embed_reserve=1.
#   MODE=clean:        no organs, no embed workload -> orch_reserve=0, embed_reserve=0.
run_plan_for_node() {
  local mode="$1" state_dir="$2"
  mkdir -p "$state_dir"
  local plan_out="$state_dir/node-capacity-plan.json"
  cat > "$FAKE_BIN/systemctl" <<EOS
#!/usr/bin/env bash
case "\$1" in
  is-active) [ "$mode" = "constrained" ] && exit 0 || exit 1 ;;
  list-units) exit 0 ;;
  *) exit 0 ;;
esac
EOS
  cat > "$FAKE_BIN/pgrep" <<EOS
#!/usr/bin/env bash
if [ "$mode" = "constrained" ]; then exit 0; else exit 1; fi
EOS
  cat > "$FAKE_BIN/nvidia-smi" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
  chmod +x "$FAKE_BIN/systemctl" "$FAKE_BIN/pgrep" "$FAKE_BIN/nvidia-smi"
  (
    export PATH="$FAKE_BIN:$PATH"
    export CHUMP_STATE_DIR="$state_dir" CHUMP_AMBIENT_LOG="$state_dir/ambient.jsonl"
    export CHUMP_PLAN_LIB_ONLY=1
    export CHUMP_PLAN_TEST_LOADPCT=20 CHUMP_PLAN_TEST_WORKERS_UP=1
    # cores: fixed at 4 regardless of host nproc, via the declared-manifest path.
    mkdir -p "$state_dir/fleet/nodes"
    export CHUMP_NODE_REGISTRY_DIR="$state_dir/fleet/nodes"
    hostname_s="$(hostname -s 2>/dev/null || hostname)"
    printf '{"cpu_cores": 4}\n' > "$state_dir/fleet/nodes/${hostname_s}.json"
    source "$PLANNER"
    plan "$plan_out"
  )
  echo "$plan_out"
}

read_worker_budget() {
  grep -o '"worker_budget": [0-9]\+' "$1" | head -1 | grep -o '[0-9]\+$'
}

STATE_CONSTRAINED="$TMPDIR_TEST/constrained"
STATE_CLEAN="$TMPDIR_TEST/clean"
plan_constrained="$(run_plan_for_node constrained "$STATE_CONSTRAINED")"
plan_clean="$(run_plan_for_node clean "$STATE_CLEAN")"

budget_constrained="$(read_worker_budget "$plan_constrained")"
budget_clean="$(read_worker_budget "$plan_clean")"

echo "  (constrained node worker_budget=$budget_constrained, clean node worker_budget=$budget_clean)"

# ── AC3: limited-resource node receives a REDUCED worker budget ────────────
if [ -n "$budget_constrained" ] && [ -n "$budget_clean" ] && [ "$budget_constrained" -lt "$budget_clean" ]; then
  ok "constrained node (orch+embed host) gets a reduced worker budget vs. the clean node on identical hardware"
else
  fail "constrained budget ($budget_constrained) is not less than clean budget ($budget_clean) on 4-core hardware"
fi
if [ "$budget_clean" -eq 3 ]; then
  ok "clean 4-core node budget matches cores-1 headroom math (3)"
else
  fail "clean 4-core node budget expected 3, got $budget_clean"
fi

# ── AC1: node-orchestrator.sh's effective_max() reads THIS budget, not a
#    blind cores-1 fallback — the allocation code consuming compute_worker_budget's
#    result to size compute workers ──────────────────────────────────────────
cat > "$FAKE_BIN/systemctl" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
chmod +x "$FAKE_BIN/systemctl"
(
  export PATH="$FAKE_BIN:$PATH"
  export CHUMP_STATE_DIR="$STATE_CONSTRAINED" CHUMP_AMBIENT_LOG="$STATE_CONSTRAINED/ambient.jsonl"
  source "$ORCH" 2>/dev/null
  CORES=4
  WORKER_MAX=0
  max="$(effective_max)"
  if [ "$max" = "$budget_constrained" ]; then
    echo "  PASS: effective_max() == constrained plan's worker_budget ($max)" >&2
    exit 0
  else
    echo "  FAIL: effective_max() returned $max, expected plan's worker_budget $budget_constrained" >&2
    exit 1
  fi
) && ok "effective_max() sizes workers from compute_worker_budget's result via the plan (not blind cores-1)" \
  || fail "effective_max() did not consume the capacity plan's worker_budget"

if [ "$budget_constrained" -lt "$((4-1))" ]; then
  ok "effective_max() path yields fewer workers than naive cores-1 fallback on the constrained node"
else
  fail "constrained worker_budget ($budget_constrained) is not below naive cores-1 (3) — reserves not taking effect"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  echo "Failures:"
  for f in "${FAILS[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
