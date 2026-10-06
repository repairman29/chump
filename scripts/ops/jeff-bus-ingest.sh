#!/usr/bin/env bash
# jeff-bus-ingest.sh — run-user-shaped wrapper for the conversation-bus inbound
# ingester (Phase A of "Mirror in the OS"). Driven by chump-jeff-bus-ingest.timer.
#
# Host-agnostic: resolves the repo root from this script's own location, points
# the ingester at the repo's canonical chump_memory.db (the same cwd-relative
# path db_pool uses), and defaults the transcript source to the run-user's
# ~/.claude/projects. No hostnames, users or absolute paths baked in.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

export CHUMP_MEMORY_DB_PATH="${CHUMP_MEMORY_DB_PATH:-$REPO_ROOT/sessions/chump_memory.db}"
export CHUMP_TRANSCRIPTS_DIR="${CHUMP_TRANSCRIPTS_DIR:-$HOME/.claude/projects}"
export CHUMP_BUS_BOT="${CHUMP_BUS_BOT:-claude-code}"

python3 "$SCRIPT_DIR/jeff-bus-ingest.py"
# META-1029: outbound leg — fleet->operator ambient events into the same bus.
export CHUMP_AMBIENT_PATH="${CHUMP_AMBIENT_PATH:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
exec python3 "$SCRIPT_DIR/jeff-bus-outbound.py"
