#!/usr/bin/env bash
# Enter Chump mode: slim the machine for the model on 8000. Stops Ollama + embed server, then kills
# every process in chump-mode.conf so vLLM-MLX (8000) + Chump Discord have maximum GPU/RAM.
# Use when running M4-max (8000 only, in-process embed). Run manually before heavy AI use.
#
# Usage: ./scripts/enter-chump-mode.sh   (from repo root, or set CHUMP_HOME)
# Logs:  logs/chump-mode.log

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
CONF="${1:-$ROOT/scripts/chump-mode.conf}"
LOG="$ROOT/logs/chump-mode.log"
mkdir -p "$ROOT/logs"

# Protected: never kill these (system + Chump AI stack: rust-agent, vLLM-MLX/Python on 8000).
PROTECTED_REGEX='^(WindowServer|loginwindow|kernel_task|launchd|sysmond|rust-agent|vllm|vllm-mlx|Python|uv run|embed_server|node.*openclaw)$'

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

# --- Slim: stop Ollama and embed server so the model on 8000 has room (M4-max uses neither). ---
kill_port() {
  local port=$1
  local name=$2
  local pids
  pids=$(lsof -ti ":$port" 2>/dev/null) || true
  if [[ -n "$pids" ]]; then
    log "Stopping $name (port $port)..."
    kill -9 $pids 2>/dev/null || true
    killed=$((killed + 1))
  fi
}

killed=0
log "=== Chump mode: slim (stop Ollama + embed), then blocklist ==="

kill_port 11434 "Ollama"
kill_port 18765 "embed server"
if killall ollama 2>/dev/null; then
  log "Stopped Ollama (killall)"
  killed=$((killed + 1))
fi

if [[ ! -f "$CONF" ]]; then
  log "No config at $CONF; skipping blocklist."
else
  log "Reading blocklist from $CONF"
  while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}}"
  line="${line%"${line##*[![:space:]]}}"
  [[ -z "$line" ]] && continue

  if [[ "$line" == bundle:* ]]; then
    bid="${line#bundle:}"
    if [[ -z "$bid" ]]; then continue; fi
    log "Quitting app (bundle): $bid"
    if osascript -e "tell application \"System Events\" to get bundle identifier of every process whose bundle identifier is \"$bid\"" 2>/dev/null | grep -q .; then
      osascript -e "tell application id \"$bid\" to quit" 2>/dev/null && { log "  quit: $bid"; killed=$((killed+1)); } || log "  quit failed or not running: $bid"
    else
      log "  not running: $bid"
    fi
    continue
  fi

  # Process name: killall (SIGTERM). Skip if it matches protected.
  if [[ "$line" =~ $PROTECTED_REGEX ]]; then
    log "Skip (protected): $line"
    continue
  fi
  if killall "$line" 2>/dev/null; then
    log "Killed: $line"
    killed=$((killed+1))
  else
    # killall returns non-zero if no matching process; not necessarily an error.
    pgrep -f "$line" >/dev/null 2>&1 && { log "Kill failed (try with sudo?): $line"; } || log "Not running: $line"
  fi
done < "$CONF"
fi

log "=== Chump mode done; processes affected: $killed ==="
