#!/usr/bin/env bash
# run-local-v2.sh — local-chump A/B harness + v2 multi-axis scoring.
#
# Wraps scripts/ab-harness/run.sh (which uses the real chump binary with
# real tools) and auto-applies scripts/ab-harness/rescore-with-v2.py to
# emit the multi-axis summary (did_attempt / hallucinated_tools / is_correct
# + Wilson 95% CIs) alongside the v1 summary.
#
# This is the harness to use for EVAL-017 (real tool integration A/B).
# Tests whether the lessons block helps when tools ARE actually available,
# not just when the agent is pretending via fake <function_calls> markup.
#
# Usage:
#   scripts/ab-harness/run-local-v2.sh \
#       --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
#       --flag CHUMP_REFLECTION_INJECTION \
#       --tag reflection-local-v2 \
#       [--limit 20] [--chump-bin ./target/release/chump]
#
# Outputs:
#   logs/ab/<tag>-<unix-ts>.jsonl                  — v1 trial rows (unchanged)
#   logs/ab/<tag>-<unix-ts>.summary.json           — v1 rollup (unchanged)
#   logs/ab/<tag>-<unix-ts>.rescored.summary.json  — v2 multi-axis + Wilson CIs
#
# All args are forwarded to run.sh verbatim. The wrapper captures the
# output path from run.sh's stdout and runs rescore-with-v2.py on the
# matching jsonl.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Forward every arg to run.sh, capture stdout so we can find the jsonl path.
OUT_LOG=$(mktemp)
trap 'rm -f "$OUT_LOG"' EXIT

echo "[run-local-v2] invoking run.sh with args: $*"
if ! "$REPO_ROOT/scripts/ab-harness/run.sh" "$@" 2>&1 | tee "$OUT_LOG"; then
    echo "[run-local-v2] run.sh failed — skipping v2 rescore" >&2
    exit 1
fi

# run.sh prints "fresh run: <path>.jsonl" near the top.
jsonl_path=$(grep -oE 'fresh run: \S+\.jsonl' "$OUT_LOG" \
                | tail -1 | awk '{print $3}')
if [[ -z "$jsonl_path" || ! -f "$jsonl_path" ]]; then
    echo "[run-local-v2] could not find jsonl output from run.sh" >&2
    echo "[run-local-v2] run.sh stdout tail:" >&2
    tail -10 "$OUT_LOG" >&2
    exit 2
fi

echo ""
echo "[run-local-v2] applying v2 rescore to $jsonl_path"
python3 "$REPO_ROOT/scripts/ab-harness/rescore-with-v2.py" "$jsonl_path"
