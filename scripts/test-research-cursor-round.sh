#!/usr/bin/env bash
# Run one cursor_improve round: improve product and Chump–Cursor (rules, docs, Cursor to implement).
# Requires: .env with TAVILY_API_KEY, CHUMP_CURSOR_CLI=1; Cursor CLI in PATH; cargo build --release.
# Run from Chump repo root.

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
# Cursor agent can run several minutes; allow 10 min for the run_cli step
export CHUMP_CLI_TIMEOUT_SECS="${CHUMP_CLI_TIMEOUT_SECS:-600}"
export DRY_RUN=1

# Same prompt as heartbeat CURSOR_IMPROVE_PROMPT (roadmap-driven)
CURSOR_IMPROVE_PROMPT='Self-improve round: improve the product and the Chump–Cursor relationship. Do not run battle_qa this round. ego read_all; task list.

1. PICK A GOAL: read_file docs/ROADMAP.md and read_file docs/CHUMP_PROJECT_BRIEF.md. Pick from an unchecked roadmap item, an open task, or Chump–Cursor improvements. Do not invent your own roadmap—use the files. Use web_search if it helps (1–2 queries); store key findings in memory.

2. MAKE CURSOR BETTER: If it would help Cursor do better: write or update .cursor/rules/*.mdc, AGENTS.md, or docs (e.g. ROADMAP.md, CHUMP_PROJECT_BRIEF.md). Use write_file or patch_file.

3. USE CURSOR TO IMPLEMENT: run_cli with agent --model auto -p "<clear goal from roadmap or task; include that Cursor should read docs/ROADMAP.md and docs/CHUMP_PROJECT_BRIEF.md>" --force. Goal is real product improvement.

4. WRAP UP: episode log; update ego; set task status if relevant. If you completed a roadmap item, patch_file or write_file docs/ROADMAP.md to change - [ ] to - [x]. notify if something is ready. Be concise.'

echo "=== Preflight ==="
if [[ -z "${TAVILY_API_KEY:-}" ]]; then
  echo "TAVILY_API_KEY is not set. Add to .env for web_search (required for cursor_improve)."
  exit 1
fi
echo "TAVILY_API_KEY: set"
echo "CHUMP_CURSOR_CLI: ${CHUMP_CURSOR_CLI:-0}"
command -v agent &>/dev/null && echo "agent (Cursor CLI): $(which agent)" || echo "agent: not in PATH"
if [[ ! -x "$ROOT/target/release/rust-agent" ]]; then
  echo "Build first: cargo build --release"
  exit 1
fi
echo ""
echo "=== Running one cursor_improve round (DRY_RUN=1) ==="
exec env "OPENAI_API_BASE=$OPENAI_API_BASE" "OPENAI_API_KEY=$OPENAI_API_KEY" "OPENAI_MODEL=$OPENAI_MODEL" \
  "TAVILY_API_KEY=$TAVILY_API_KEY" \
  "CHUMP_CURSOR_CLI=${CHUMP_CURSOR_CLI:-1}" \
  "$ROOT/target/release/rust-agent" --chump "$CURSOR_IMPROVE_PROMPT"
