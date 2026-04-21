#!/usr/bin/env bash
# run-real-tools.sh — EVAL-017: Real-tool integration A/B harness.
#
# Runs the real_tool_tasks.json fixture against the LOCAL chump binary
# (which has access to real tools: read_file, run_cli, grep, etc.).
# Mode A = CHUMP_REFLECTION_INJECTION=1, Mode B = 0.
#
# After the local run, applies v2 multi-axis rescoring via rescore-with-v2.py
# so the results are comparable to the cloud v2 runs.
#
# Usage:
#   scripts/ab-harness/run-real-tools.sh [--limit 20] [--chump-bin ./target/release/chump]
#
# Prerequisites:
#   - chump binary built (cargo build --release)
#   - LLM endpoint reachable ($OPENAI_API_BASE or Ollama at :11434)
#
# Output:
#   logs/ab/real-tools-<unix-ts>.jsonl
#   logs/ab/real-tools-<unix-ts>-rescored.summary.json  (v2 multi-axis)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE="$SCRIPT_DIR/fixtures/real_tool_tasks.json"
CHUMP_BIN="$ROOT/target/release/chump"
LIMIT="${1:-20}"
TAG="real-tools"

# Pass extra args through to run.sh
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)    LIMIT="$2"; shift 2;;
    --chump-bin) CHUMP_BIN="$2"; shift 2;;
    *)          EXTRA_ARGS+=("$1"); shift;;
  esac
done

echo "[run-real-tools] Running A/B with CHUMP_REFLECTION_INJECTION flag…"
echo "[run-real-tools] fixture: $FIXTURE"
echo "[run-real-tools] limit: $LIMIT"
echo ""

# Run the local A/B harness.
TS="$(date +%s)"
TRIALS="$ROOT/logs/ab/${TAG}-${TS}.jsonl"

"$SCRIPT_DIR/run.sh" \
    --fixture "$FIXTURE" \
    --flag    CHUMP_REFLECTION_INJECTION \
    --tag     "$TAG" \
    --limit   "$LIMIT" \
    --chump-bin "$CHUMP_BIN" \
    "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"

echo ""
echo "[run-real-tools] Applying v2 multi-axis rescoring…"
python3.12 "$SCRIPT_DIR/rescore-with-v2.py" "$TRIALS"

echo ""
echo "[run-real-tools] done."
echo "[run-real-tools] v2 summary: ${TRIALS%.jsonl}-rescored.summary.json"
