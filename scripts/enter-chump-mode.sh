#!/usr/bin/env bash
# Enter Chump mode: kill only the processes listed in chump-mode.conf to free RAM/CPU for the 30B stack.
# Safe blocklist approach — never kills system or Chump-related processes. Run manually when you want
# to maximize resources for vLLM-MLX + Discord + heartbeats (e.g. before an overnight run).
#
# Usage: ./scripts/enter-chump-mode.sh   (from repo root, or set CHUMP_HOME)
# Logs:  logs/chump-mode.log

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
CONF="${1:-$ROOT/scripts/chump-mode.conf}"
LOG="$ROOT/logs/chump-mode.log"
mkdir -p "$ROOT/logs"

# Protected: never kill these (system + Chump AI stack). Do not add Cursor/Discord client here — add those to the blocklist if you want them killed.
PROTECTED_REGEX='^(WindowServer|loginwindow|kernel_task|launchd|sysmond|rust-agent|vllm|ollama|Python|uv run|embed_server|node.*openclaw)$'

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

if [[ ! -f "$CONF" ]]; then
  log "No config at $CONF; exit."
  exit 1
fi

log "=== Chump mode: reading blocklist from $CONF ==="

killed=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="${line// /}"
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

log "=== Chump mode done; processes affected: $killed ==="
