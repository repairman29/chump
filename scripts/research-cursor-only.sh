#!/usr/bin/env bash
# Run one cursor_improve round: improve product and Chump–Cursor relationship (rules, docs, Cursor to implement).
# For scheduling: cron or launchd every 2–4h. Same goal as heartbeat cursor_improve round.
# Requires: .env with TAVILY_API_KEY, CHUMP_CURSOR_CLI=1, CURSOR_API_KEY; agent in PATH; cargo build --release.
# Run from Chump repo root.
#
# Usage:
#   ./scripts/research-cursor-only.sh              # interactive, logs to stdout + LOG
#   ./scripts/research-cursor-only.sh >> logs/... 2>&1   # background
#   HEARTBEAT_DRY_RUN=0 ./scripts/research-cursor-only.sh   # allow push/PR (use with care)

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${HOME}/.cursor/bin:${PATH}"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

export OPENAI_API_BASE="${OPENAI_API_BASE:-http://localhost:11434/v1}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-not-needed}"
export OPENAI_MODEL="${OPENAI_MODEL:-qwen2.5:14b}"
export CHUMP_CLI_TIMEOUT_SECS="${CHUMP_CLI_TIMEOUT_SECS:-600}"
export DRY_RUN="${HEARTBEAT_DRY_RUN:-${DRY_RUN:-1}}"

LOG="$ROOT/logs/research-cursor-only.log"
mkdir -p "$ROOT/logs"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] research-cursor-only (cursor_improve): starting" >> "$LOG"

if [[ -z "${TAVILY_API_KEY:-}" ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] research-cursor-only: TAVILY_API_KEY not set; exit 1" >> "$LOG"
  exit 1
fi
if [[ ! -x "$ROOT/target/release/rust-agent" ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] research-cursor-only: rust-agent not built; exit 1" >> "$LOG"
  exit 1
fi

# Same goal as heartbeat CURSOR_IMPROVE_PROMPT: improve product and Chump–Cursor relationship; use roadmap.
CURSOR_IMPROVE_PROMPT='Self-improve round: improve the product and the Chump–Cursor relationship. Do not run battle_qa this round. ego read_all; task list.

1. PICK A GOAL: read_file docs/ROADMAP.md and read_file docs/CHUMP_PROJECT_BRIEF.md. Pick from: an unchecked item in the roadmap, an open task, a codebase gap, or improving how Chump and Cursor work together. Do not invent your own roadmap—use the files. Use web_search if it helps (1–2 queries); store key findings in memory.

2. MAKE CURSOR BETTER: If it would help Cursor do better in this repo: write or update .cursor/rules/*.mdc, AGENTS.md, or docs Cursor sees (e.g. CURSOR_CLI_INTEGRATION.md, ROADMAP.md, CHUMP_PROJECT_BRIEF.md). Use write_file or edit_file.

3. USE CURSOR TO IMPLEMENT: run_cli with agent --model auto -p "<clear goal from roadmap or task; include 1–2 bullets of context or that Cursor should read docs/ROADMAP.md and docs/CHUMP_PROJECT_BRIEF.md>" --force. Goal is real product improvement, not just research.

4. WRAP UP: episode log; update ego; set task status if relevant. If you completed a roadmap item, edit_file docs/ROADMAP.md to change that item from - [ ] to - [x]. notify if something is ready. Be concise.'

if env "OPENAI_API_BASE=$OPENAI_API_BASE" "OPENAI_API_KEY=$OPENAI_API_KEY" "OPENAI_MODEL=$OPENAI_MODEL" \
  "TAVILY_API_KEY=$TAVILY_API_KEY" "CHUMP_CURSOR_CLI=${CHUMP_CURSOR_CLI:-1}" \
  "CHUMP_CLI_TIMEOUT_SECS=$CHUMP_CLI_TIMEOUT_SECS" "DRY_RUN=$DRY_RUN" \
  "$ROOT/target/release/rust-agent" --chump "$CURSOR_IMPROVE_PROMPT" >> "$LOG" 2>&1; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] research-cursor-only: ok" >> "$LOG"
else
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] research-cursor-only: exit non-zero" >> "$LOG"
  exit 1
fi
