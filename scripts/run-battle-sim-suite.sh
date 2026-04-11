#!/usr/bin/env bash
# Orchestrate fast simulations: unit/API contract tests, optional CLI no-LLM, optional live web API sim.
#
# Usage:
#   ./scripts/run-battle-sim-suite.sh
#   BATTLE_SIM_WEB=1 ./scripts/run-battle-sim-suite.sh   # requires chump --web already running
#
# For LLM-backed smoke (needs Ollama/vLLM):
#   BATTLE_SIM_LLM=1 ./scripts/run-battle-sim-suite.sh
#
# CI sets BATTLE_SIM_SKIP_CARGO=1 when cargo test already ran (suite still runs CLI + optional sims).

set -euo pipefail
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

if [[ "${BATTLE_SIM_SKIP_CARGO:-}" != "1" ]]; then
  echo "=== 1/4 cargo test (includes web API contract tests) ==="
  cargo test -q --workspace
else
  echo "=== 1/4 cargo test skipped (BATTLE_SIM_SKIP_CARGO=1; CI already ran tests) ==="
fi

echo "=== 2/4 CLI no-LLM ==="
./scripts/battle-cli-no-llm.sh

if [[ "${BATTLE_SIM_WEB:-}" == "1" ]]; then
  echo "=== 3/4 battle-api-sim (live web) ==="
  ./scripts/battle-api-sim.sh
else
  echo "=== 3/4 battle-api-sim skipped (set BATTLE_SIM_WEB=1 with web running) ==="
fi

if [[ "${BATTLE_SIM_LLM:-}" == "1" ]]; then
  echo "=== 4/4 battle-qa fast query set ==="
  export BATTLE_QA_QUERIES="${BATTLE_QA_QUERIES:-$ROOT/scripts/qa/battle-fast-queries.txt}"
  BATTLE_QA_MAX="${BATTLE_QA_MAX:-60}" BATTLE_QA_ITERATIONS=1 ./scripts/battle-qa.sh
else
  echo "=== 4/4 battle-qa skipped (set BATTLE_SIM_LLM=1 + model server) ==="
fi

echo "=== battle-sim suite complete ==="
