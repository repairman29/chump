#!/usr/bin/env bash
# run.sh — INFRA-691: canonical entrypoint for all Chump run modes.
#
# Usage: ./run.sh <mode> [args...]
#
# Modes:
#   local           Run against local Ollama (default mode)
#   best            Run against vLLM-MLX (port 8000)
#   web             Start the PWA web server
#   discord         Run the Discord bot (Ollama backend)
#   discord-full    Run Discord with full tool set + vLLM-MLX
#   discord-ollama  Run Discord with explicit Ollama check
#
# Examples:
#   ./run.sh local
#   ./run.sh web --port 8080
#   ./run.sh discord
#
# Legacy scripts (run-local.sh, run-web.sh, etc.) are thin shims pointing
# here and will be removed in a future release.

set -e
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

_usage() {
    grep '^#' "$0" | sed 's/^# \{0,1\}//' | grep -v '^!' | tail -n +2
    exit "${1:-0}"
}

MODE="${1:-}"
if [[ -z "$MODE" || "$MODE" == "--help" || "$MODE" == "-h" ]]; then
    _usage 0
fi
shift

case "$MODE" in
    local)
        exec "$REPO_ROOT/run-local.sh" "$@"
        ;;
    best)
        exec "$REPO_ROOT/run-best.sh" "$@"
        ;;
    web)
        exec "$REPO_ROOT/run-web.sh" "$@"
        ;;
    discord)
        exec "$REPO_ROOT/run-discord.sh" "$@"
        ;;
    discord-full)
        exec "$REPO_ROOT/run-discord-full.sh" "$@"
        ;;
    discord-ollama)
        exec "$REPO_ROOT/run-discord-ollama.sh" "$@"
        ;;
    *)
        echo "run.sh: unknown mode '$MODE'" >&2
        echo "Run './run.sh --help' for usage." >&2
        exit 2
        ;;
esac
