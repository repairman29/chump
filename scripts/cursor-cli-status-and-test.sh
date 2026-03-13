#!/usr/bin/env bash
# Show what's running and run the Cursor CLI integration test.
# Run from Chump repo root: bash scripts/cursor-cli-status-and-test.sh

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

# Cursor CLI installer puts binary in ~/.local/bin (darwin); ensure it's findable
export PATH="$HOME/.local/bin:$HOME/.cursor/bin:$PATH"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

echo "========== WHAT'S RUNNING =========="
echo ""
echo "Model server:"
if [[ -f "$ROOT/.env" ]]; then set -a; source "$ROOT/.env" 2>/dev/null; set +a; fi
BASE="${OPENAI_API_BASE:-http://localhost:11434/v1}"
if [[ "$BASE" == *"11434"* ]]; then
  if curl -s -o /dev/null -w "%{http_code}" --max-time 2 http://127.0.0.1:11434/api/tags 2>/dev/null | grep -q 200; then
    echo "  Ollama (11434): OK"
  else
    echo "  Ollama (11434): NOT reachable — run: ollama serve"
  fi
else
  port="${BASE#*:}"; port="${port%%/*}"
  if curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:${port}/v1/models" 2>/dev/null | grep -q 200; then
    echo "  vLLM ($port): OK"
  else
    echo "  vLLM ($port): NOT reachable — run: ./serve-vllm-mlx.sh"
  fi
fi

echo ""
echo "Chump processes:"
if pgrep -fl "heartbeat-self-improve|rust-agent" 2>/dev/null; then
  echo "  (above processes are running; kill with: pkill -f heartbeat-self-improve; pkill -f 'rust-agent')"
else
  echo "  none"
fi

echo ""
echo "Cursor CLI (agent):"
if command -v agent &>/dev/null; then
  echo "  OK: $(which agent)"
  agent --version 2>/dev/null || true
else
  echo "  NOT in PATH (checked PATH, ~/.local/bin, ~/.cursor/bin)"
  echo "  Install: curl https://cursor.com/install -fsS | bash"
  echo "  Then: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
fi

echo ""
echo "CHUMP_CURSOR_CLI in .env:"
echo "  ${CHUMP_CURSOR_CLI:-not set}"

echo ""
echo "Chump release binary:"
if [[ -x "$ROOT/target/release/rust-agent" ]]; then
  echo "  OK: $ROOT/target/release/rust-agent"
else
  echo "  missing — run: cargo build --release"
fi

echo ""
echo "========== RUNNING TEST =========="
# Use run-local.sh so Ollama env is always set (no 401)
if [[ ! -x "$ROOT/target/release/rust-agent" ]]; then
  echo "Skipping test: build release first (cargo build --release)"
  exit 1
fi

if ! command -v agent &>/dev/null; then
  echo "Skipping step 3 (Chump one-shot): Cursor CLI (agent) not in PATH. Install it, then re-run this script."
  exit 1
fi

if [[ "${CHUMP_CURSOR_CLI:-0}" != "1" ]]; then
  echo "Skipping: CHUMP_CURSOR_CLI is not 1. Add CHUMP_CURSOR_CLI=1 to .env and re-run."
  exit 1
fi

CURSOR_CLI_TEST_TIMEOUT="${CURSOR_CLI_TEST_TIMEOUT:-90}"
echo "Chump one-shot (via run-local.sh)..."
if command -v timeout >/dev/null 2>&1; then
  timeout "$CURSOR_CLI_TEST_TIMEOUT" "$ROOT/run-local.sh" --chump "You have Cursor CLI enabled. Reply in one short sentence with the exact run_cli command: use agent -p \"<description>\" --force (e.g. agent --model auto -p \"fix the failing tests in logs/battle-qa-failures.txt\" --force). Do not execute it." 2>&1 | tail -25
else
  "$ROOT/run-local.sh" --chump "You have Cursor CLI enabled. Reply in one short sentence with the exact run_cli command: use agent -p \"<description>\" --force (e.g. agent --model auto -p \"fix the failing tests in logs/battle-qa-failures.txt\" --force). Do not execute it." 2>&1 | tail -25
fi

echo ""
echo "========== DONE =========="
echo "If you saw a reply above, Chump knows the Cursor CLI pattern. To test a real Cursor call:"
echo "  ./run-local.sh --chump \"Use Cursor CLI to run: agent --model auto -p 'echo hello from Cursor' --force. Tell me the output.\""
