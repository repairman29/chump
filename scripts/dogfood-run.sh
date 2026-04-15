#!/usr/bin/env bash
# Run Chump on its own codebase (dogfood mode).
# Picks a task from the dogfood queue and executes it via autonomy_once.
#
# Usage:
#   ./scripts/dogfood-run.sh                    # pick next task from queue
#   ./scripts/dogfood-run.sh "fix clippy warning in src/foo.rs"  # one-shot prompt
#
# Prerequisites:
#   - Ollama running with a 14B model
#   - .env configured with OPENAI_API_BASE pointing to Ollama
#
# Output: logs/dogfood/<timestamp>.log
set -euo pipefail

ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

# Ensure logs directory
mkdir -p logs/dogfood

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG="logs/dogfood/${TIMESTAMP}.log"

# Dogfood-specific env: full tool profile, point repo at self, autoload patterns
export CHUMP_TOOL_PROFILE=full
export CHUMP_REPO="$ROOT"
export CHUMP_HOME="$ROOT"
# Copy codebase patterns into brain if not present
if [[ -d "$ROOT/chump-brain" ]] && [[ ! -f "$ROOT/chump-brain/rust-codebase-patterns.md" ]]; then
    cp "$ROOT/docs/RUST_CODEBASE_PATTERNS.md" "$ROOT/chump-brain/rust-codebase-patterns.md" 2>/dev/null || true
fi

export CHUMP_BRAIN_AUTOLOAD="self.md,rust-codebase-patterns.md"
export CHUMP_TEST_AWARE=1
# Auto-approve all tools for dogfood — Chump is operating on its own repo
export CHUMP_AUTO_APPROVE_TOOLS="run_cli,read_file,write_file,patch_file,rg,task,memory_brain,list_files"
export CHUMP_AUTO_APPROVE_LOW_RISK=1

# Use the local .env for inference config (but don't clobber pre-set env vars)
_SAVED_MODEL="${OPENAI_MODEL:-}"
if [[ -f "$ROOT/.env" ]]; then
    set -a
    source "$ROOT/.env"
    set +a
fi
# Restore caller-provided overrides
if [[ -n "$_SAVED_MODEL" ]]; then
    export OPENAI_MODEL="$_SAVED_MODEL"
fi

# Override: always full profile for dogfood
export CHUMP_TOOL_PROFILE=full

echo "=== Chump dogfood run: $TIMESTAMP ===" | tee "$LOG"
echo "Repo: $ROOT" | tee -a "$LOG"
echo "Model: ${OPENAI_MODEL:-unknown}" | tee -a "$LOG"
echo "Log: $LOG" | tee -a "$LOG"
echo "" | tee -a "$LOG"

if [[ $# -gt 0 ]]; then
    # One-shot prompt mode
    PROMPT="$*"
    echo "Mode: one-shot prompt" | tee -a "$LOG"
    echo "Prompt: $PROMPT" | tee -a "$LOG"
    echo "" | tee -a "$LOG"

    cargo run --release --bin chump -- --chump "$PROMPT" 2>&1 | tee -a "$LOG"
else
    # Autonomy mode: pick from task queue
    echo "Mode: autonomy_once (picks next task from queue)" | tee -a "$LOG"
    echo "" | tee -a "$LOG"

    cargo run --release --bin chump -- --autonomy-once 2>&1 | tee -a "$LOG"
fi

EXIT_CODE=$?
echo "" | tee -a "$LOG"
echo "=== Exit code: $EXIT_CODE ===" | tee -a "$LOG"
echo "=== Log saved: $LOG ===" | tee -a "$LOG"
