#!/usr/bin/env bash
# Unified Discord bot control — start, stop, restart, status
# Intelligently selects the right variant based on .env and current setup
#
# Usage:
#   ./scripts/discord.sh start    — Start bot (auto-selects variant: ollama, vllm, or full)
#   ./scripts/discord.sh stop     — Stop bot
#   ./scripts/discord.sh restart  — Stop and start
#   ./scripts/discord.sh status   — Show running status and config
#   ./scripts/discord.sh help     — Show this help

set -e
cd "$(dirname "$0")/.."

# Load environment
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

REPO_ROOT="$(pwd)"
export CHUMP_HOME="${CHUMP_HOME:-$REPO_ROOT}"
export CHUMP_REPO="${CHUMP_REPO:-$REPO_ROOT}"

# Logging helpers
log_info() {
  echo "ℹ️  $*"
}

log_success() {
  echo "✅ $*"
}

log_error() {
  echo "❌ $*" >&2
}

# Check if Discord bot is running
is_running() {
  pgrep -f "chump.*--discord" >/dev/null 2>&1 || pgrep -f "rust-agent.*--discord" >/dev/null 2>&1
}

# Determine which Discord variant to use based on .env and system state
select_variant() {
  # Check if mistral.rs is configured
  if [[ -x "./scripts/setup/inference-primary-mistralrs.sh" ]] && "./scripts/setup/inference-primary-mistralrs.sh" 2>/dev/null; then
    echo "mistralrs"
    return
  fi

  # Check if vLLM is configured
  if [[ -n "${OPENAI_API_BASE:-}" ]] && [[ "$OPENAI_API_BASE" == *"8000"* || "$OPENAI_API_BASE" == *"8001"* ]]; then
    echo "vllm"
    return
  fi

  # Check if we should use full variant (inprocess-embed)
  if [[ "${CHUMP_DISCORD_FULL:-0}" == "1" ]] || [[ "${CHUMP_DISCORD_FULL:-0}" == "true" ]]; then
    echo "full"
    return
  fi

  # Default: Ollama
  echo "ollama"
}

# Start the bot
discord_start() {
  if is_running; then
    log_error "Discord bot is already running"
    echo "Stop it first: ./scripts/discord.sh stop"
    return 1
  fi

  local variant=$(select_variant)
  log_info "Starting Discord bot (variant: $variant)..."

  case "$variant" in
    mistralrs)
      log_info "Using mistral.rs in-process inference"
      mkdir -p logs
      exec cargo run --release -- --discord
      ;;
    vllm)
      log_info "Using vLLM at $OPENAI_API_BASE"
      mkdir -p logs
      exec cargo run --release -- --discord
      ;;
    full)
      log_info "Building with full tools (inprocess-embed, vLLM, repo tools)..."
      cargo build --release --features inprocess-embed
      mkdir -p logs
      exec ./target/release/chump --discord
      ;;
    ollama)
      if pgrep -f "ollama" >/dev/null 2>&1; then
        log_info "Using Ollama (already running)"
      else
        log_error "Ollama not running. Start it: ollama serve"
        return 1
      fi

      mkdir -p logs
      if [[ -x ./target/release/chump ]]; then
        exec ./target/release/chump --discord
      elif [[ -x ./target/debug/chump ]]; then
        exec ./target/debug/chump --discord
      else
        exec cargo run -- --discord
      fi
      ;;
    *)
      log_error "Unknown variant: $variant"
      return 1
      ;;
  esac
}

# Stop the bot
discord_stop() {
  local count=0
  while pgrep -f "chump.*--discord" >/dev/null 2>&1 || pgrep -f "rust-agent.*--discord" >/dev/null 2>&1; do
    pkill -f "chump.*--discord" 2>/dev/null || true
    pkill -f "rust-agent.*--discord" 2>/dev/null || true
    count=$((count + 1))
    sleep 0.5
  done

  if [[ $count -gt 0 ]]; then
    log_success "Stopped $count Discord process(es)"
  else
    log_info "No Discord process was running"
  fi
}

# Show bot status
discord_status() {
  if is_running; then
    log_success "Discord bot is running"
    local variant=$(select_variant)
    log_info "Variant: $variant"
    log_info "Model: ${OPENAI_MODEL:-qwen2.5:14b}"
    log_info "API base: ${OPENAI_API_BASE:-http://localhost:11434/v1}"
    if [[ -n "${DISCORD_TOKEN:-}" ]]; then
      log_info "Token: set ($(echo $DISCORD_TOKEN | cut -c1-4)...)"
    else
      log_error "Token: NOT SET"
    fi
  else
    log_error "Discord bot is not running"
    return 1
  fi
}

# Show help
show_help() {
  cat <<'EOF'
Discord bot unified control

Usage:
  ./scripts/discord.sh start    Start bot (auto-selects variant)
  ./scripts/discord.sh stop     Stop bot
  ./scripts/discord.sh restart  Stop and start
  ./scripts/discord.sh status   Show running status
  ./scripts/discord.sh help     Show this help

Configuration (.env):
  DISCORD_TOKEN           (required) Discord bot token
  OPENAI_API_BASE         API endpoint (default: http://localhost:11434/v1)
  OPENAI_API_KEY          API key (default: ollama)
  OPENAI_MODEL            Model name (default: qwen2.5:14b)
  CHUMP_DISCORD_FULL      Set to 1 to use full variant with inprocess-embed

Variants:
  ollama    — Ollama at localhost:11434 (default)
  vllm      — vLLM at localhost:8000 or 8001
  mistralrs — mistral.rs in-process (if available)
  full      — Full tools with inprocess-embed + vLLM (CHUMP_DISCORD_FULL=1)

Examples:
  # Start with Ollama (default)
  ./scripts/discord.sh start

  # Start with vLLM
  OPENAI_API_BASE=http://localhost:8000/v1 ./scripts/discord.sh start

  # Restart and show status
  ./scripts/discord.sh restart && ./scripts/discord.sh status

For troubleshooting, see: docs/operations/DISCORD_TROUBLESHOOTING.md
EOF
}

# Main
case "${1:-help}" in
  start)
    discord_start
    ;;
  stop)
    discord_stop
    ;;
  restart)
    discord_stop
    sleep 1
    discord_start
    ;;
  status)
    discord_status
    ;;
  help)
    show_help
    ;;
  *)
    log_error "Unknown command: $1"
    show_help
    exit 1
    ;;
esac
