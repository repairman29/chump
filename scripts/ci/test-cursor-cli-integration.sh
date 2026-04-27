#!/usr/bin/env bash
# Test Cursor CLI integration: ensure agent is in PATH, then run Chump with a prompt
# that should trigger the Cursor CLI path (soul says to use run_cli agent -p ... --force).
# Run from Chump repo root.

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"

# Cursor CLI installer puts binary in ~/.local/bin (darwin); ensure it's findable
export PATH="$HOME/.local/bin:$HOME/.cursor/bin:$PATH"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

echo "=== 1. Check CHUMP_CURSOR_CLI ==="
if [[ "${CHUMP_CURSOR_CLI:-0}" != "1" ]]; then
  echo "CHUMP_CURSOR_CLI is not 1. Set in .env: CHUMP_CURSOR_CLI=1"
  exit 1
fi
echo "OK: CHUMP_CURSOR_CLI=1"

echo ""
echo "=== 2. Check Cursor CLI (agent) in PATH ==="
if ! command -v agent &>/dev/null; then
  echo "agent not found (checked PATH, ~/.local/bin, ~/.cursor/bin). Install Cursor CLI:"
  echo "  curl https://cursor.com/install -fsS | bash"
  echo "Then: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
  exit 1
fi
echo "OK: $(which agent)"
agent --version 2>/dev/null || true

# Preflight: model server reachable
echo ""
echo "=== 3. Preflight: model server ==="
if ! "$ROOT/scripts/ci/check-heartbeat-preflight.sh" &>/dev/null; then
  echo "SKIP: model server not reachable. Start Ollama (ollama serve) or vLLM-MLX on 8000, then re-run."
  exit 1
fi
echo "OK: model server reachable"

echo ""
echo "=== 4. Chump one-shot: ask what Cursor CLI command he would use ==="
PROMPT="You have Cursor CLI enabled. Reply in one short sentence: what exact run_cli command would you use to ask Cursor to fix the failing tests listed in logs/battle-qa-failures.txt? Do not execute it."
export OPENAI_API_BASE="${OPENAI_API_BASE:-http://localhost:11434/v1}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-not-needed}"
export OPENAI_MODEL="${OPENAI_MODEL:-qwen2.5:14b}"
CURSOR_CLI_TEST_TIMEOUT="${CURSOR_CLI_TEST_TIMEOUT:-90}"

if [[ -x "$ROOT/target/release/chump" ]]; then
  if command -v timeout >/dev/null 2>&1; then
    timeout "$CURSOR_CLI_TEST_TIMEOUT" "$ROOT/target/release/chump" --chump "$PROMPT" 2>&1 | tail -30
  else
    "$ROOT/target/release/chump" --chump "$PROMPT" 2>&1 | tail -30
  fi
else
  echo "Build release first: cargo build --release"
  exit 1
fi

echo ""
echo "=== 5. Optional: real Cursor CLI invocation (run from repo root) ==="
echo "To test a real call, run:"
echo "  cd $ROOT && ./target/release/chump --chump 'Use Cursor CLI to fix this: run agent -p \"echo Cursor CLI integration test\" --force and tell me the output.'"
echo "Or in Discord, say: \"Use Cursor to fix the battle QA failures\" (when you have Cursor CLI in PATH)."
