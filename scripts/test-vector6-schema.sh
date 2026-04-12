#!/usr/bin/env bash
# Vector 6 autonomous verification: deterministic mock provider proves schema interception
# + synthetic retry + successful task execution. Output -> logs/vector6-test.log
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/logs"
cd "$ROOT"
export CHUMP_REPO="${CHUMP_REPO:-$ROOT}"
export RUST_LOG="${RUST_LOG:-info,rust_agent::agent_loop=info}"
export CHUMP_CLUSTER_MODE="${CHUMP_CLUSTER_MODE:-0}"
# Mock-only run finishes in seconds (no real LLM). macOS may lack `timeout(1)`.
if command -v timeout >/dev/null 2>&1; then
  timeout 60 cargo run --bin chump -- --vector6-verify 2>&1 | tee "$ROOT/logs/vector6-test.log"
else
  cargo run --bin chump -- --vector6-verify 2>&1 | tee "$ROOT/logs/vector6-test.log"
fi
