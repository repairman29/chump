#!/usr/bin/env bash
# Vector 7: prove CHUMP_CLUSTER_MODE=1 hits SwarmExecutor ([SWARM ROUTER]) and tools still run locally.
# Deterministic path: `cargo run --bin chump -- --vector7-swarm-verify` (mock provider + same prompt text).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/logs"
cd "$ROOT"
export CHUMP_REPO="${CHUMP_REPO:-$ROOT}"
export CHUMP_CLUSTER_MODE=1
export RUST_LOG="${RUST_LOG:-info,rust_agent::task_executor=info,rust_agent::agent_loop=info}"
if command -v timeout >/dev/null 2>&1; then
  timeout 120 cargo run --bin chump -- --vector7-swarm-verify 2>&1 | tee "$ROOT/logs/vector7-test.log"
else
  cargo run --bin chump -- --vector7-swarm-verify 2>&1 | tee "$ROOT/logs/vector7-test.log"
fi
