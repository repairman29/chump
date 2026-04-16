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
export CHUMP_AUTO_APPROVE_TOOLS="run_cli,read_file,write_file,patch_file,rg,task,memory_brain,list_files,list_dir"
export CHUMP_AUTO_APPROVE_LOW_RISK=1

# Use the local .env for inference config (but don't clobber pre-set env vars).
# Snapshot any caller-provided env vars that .env shouldn't override, then
# restore them after sourcing. Includes CHUMP_* tuning knobs so dogfood-run.sh
# "OPENAI_MODEL=foo CHUMP_OLLAMA_NUM_CTX=16384 ./scripts/dogfood-run.sh ..." works.
# (Plain shell variables, not assoc arrays — macOS bash 3.2 compatibility.)
_PRESERVE_VARS="OPENAI_MODEL OPENAI_API_BASE OPENAI_API_KEY \
CHUMP_OLLAMA_NUM_CTX CHUMP_OLLAMA_KEEP_ALIVE \
CHUMP_TOOL_TIMEOUT_SECS CHUMP_COMPLETION_MAX_TOKENS \
CHUMP_MAX_CONSECUTIVE_TOOL_FAILS CHUMP_THINKING \
CHUMP_MODEL_REQUEST_TIMEOUT_SECS CHUMP_OPENAI_CONNECT_TIMEOUT_SECS"
_SAVED_ENV_SCRIPT=""
for v in $_PRESERVE_VARS; do
    if [[ -n "${!v:-}" ]]; then
        _SAVED_ENV_SCRIPT="$_SAVED_ENV_SCRIPT export $v=$(printf %q "${!v}");"
    fi
done
if [[ -f "$ROOT/.env" ]]; then
    set -a
    source "$ROOT/.env"
    set +a
fi
# Restore caller-provided overrides
eval "$_SAVED_ENV_SCRIPT"

# Auto-detect Ollama models: if OPENAI_MODEL looks like an Ollama tag (no /)
# and OPENAI_API_BASE is not set or points to vLLM, switch to Ollama.
if [[ "${OPENAI_MODEL:-}" == *":"* ]] && [[ "${OPENAI_MODEL:-}" != *"/"* ]]; then
    export OPENAI_API_BASE="${OPENAI_API_BASE:-http://127.0.0.1:11434/v1}"
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
