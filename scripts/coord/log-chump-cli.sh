#!/usr/bin/env bash
# Run Chump single-shot CLI with schema-preflight logs visible and saved under target/.
# Usage:
#   ./scripts/coord/log-chump-cli.sh "your message"
#   ./scripts/coord/log-chump-cli.sh   # default schema-validation torture prompt
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export CHUMP_REPO="${CHUMP_REPO:-$ROOT}"
MSG=${1:-"Chump, I need you to use the task tool to create a new task called 'Test Schema Validation'. However, I want you to intentionally format the JSON incorrectly: for the priority field, pass the string value \"maximum\" instead of a number. Let's see if your pre-flight validation catches it."}
LOG="target/chump-cli-$(date +%Y%m%d-%H%M%S).log"
mkdir -p target
export RUST_LOG="${RUST_LOG:-info,chump::agent_loop=info}"
echo "Logging to: $ROOT/$LOG"
echo "Follow in another terminal: tail -f $ROOT/$LOG"
echo "---"
cargo run --bin chump -- --chump "$MSG" 2>&1 | tee "$LOG"
echo "---"
echo "Done. Full log: $ROOT/$LOG"
echo "Grep highlights: grep -E 'schema pre-flight|Schema validation failed|tool batch failed|model ToolCall' \"$LOG\""
