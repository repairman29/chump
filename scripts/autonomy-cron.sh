#!/usr/bin/env bash
# autonomy-cron.sh — cron/supervisor-friendly autonomy runner (single task per run).
#
# Usage:
#   ./scripts/autonomy-cron.sh
#   CHUMP_AUTONOMY_ASSIGNEE=chump ./scripts/autonomy-cron.sh
#
# This script is intentionally boring and reliable:
# - runs exactly one autonomy loop iteration
# - logs stdout/stderr to logs/autonomy-cron.log
# - exits 0 even when no tasks are available (noop)

set -euo pipefail

ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
mkdir -p "$ROOT/logs"

LOG="$ROOT/logs/autonomy-cron.log"

[[ -f .env ]] && set -a && source .env && set +a

ASSIGNEE="${CHUMP_AUTONOMY_ASSIGNEE:-chump}"

# Release binary name is `chump` (see Cargo.toml [[bin]])
if [[ -x "$ROOT/target/release/chump" ]]; then
  BIN="$ROOT/target/release/chump"
else
  BIN=""
fi

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

{
  echo "[$(ts)] autonomy-cron: start (assignee=$ASSIGNEE)"
  # Preflight: clear expired task leases and requeue stale in_progress (deterministic, non-LLM).
  if [[ -n "$BIN" ]]; then
    "$BIN" --reap-leases
  else
    cargo run -q -- --reap-leases
  fi
  if [[ -n "$BIN" ]]; then
    CHUMP_AUTONOMY_ASSIGNEE="$ASSIGNEE" "$BIN" --autonomy-once
  else
    CHUMP_AUTONOMY_ASSIGNEE="$ASSIGNEE" cargo run -q -- --autonomy-once
  fi
  echo "[$(ts)] autonomy-cron: done"
} >>"$LOG" 2>&1

