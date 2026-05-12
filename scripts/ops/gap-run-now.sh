#!/usr/bin/env bash
# gap-run-now.sh — INFRA-895
#
# Triggers immediate dispatch of a gap outside the normal scheduler cycle.
# Validates the gap is open and unclaimed, then invokes the worker with
# the specified gap override.
#
# Usage:
#   gap-run-now.sh <GAP-ID> [--dry-run] [--model MODEL] [--timeout SECONDS]
#
# Options:
#   --dry-run           Validate and log intent without running worker
#   --model MODEL       Override FLEET_MODEL for this run
#   --timeout SECONDS   Override FLEET_TIMEOUT_S (default: 1800)
#
# Environment:
#   REPO_ROOT           Repo root
#   CHUMP_AMBIENT_LOG   Path to ambient.jsonl
#   FLEET_MODEL         Model to use (haiku|sonnet|opus)
#   FLEET_TIMEOUT_S     Worker timeout in seconds
#
# Exit codes:
#   0 = dispatch succeeded (or --dry-run passed)
#   1 = validation failed (gap not found, already claimed, not open)
#   2 = worker exited non-zero

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
DRY_RUN=0
MODEL_OVERRIDE=""
TIMEOUT_OVERRIDE=""
GAP_ID=""

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=1;              shift ;;
        --model)    MODEL_OVERRIDE="$2";    shift 2 ;;
        --timeout)  TIMEOUT_OVERRIDE="$2";  shift 2 ;;
        -h|--help)
            echo "Usage: gap-run-now.sh <GAP-ID> [--dry-run] [--model MODEL] [--timeout SECS]"
            exit 0 ;;
        -*)
            echo "Unknown option: $1" >&2; exit 1 ;;
        *)
            if [[ -z "$GAP_ID" ]]; then GAP_ID="$1"; shift
            else echo "Unexpected argument: $1" >&2; exit 1
            fi ;;
    esac
done

if [[ -z "$GAP_ID" ]]; then
    echo "Usage: gap-run-now.sh <GAP-ID> [--dry-run] [--model MODEL] [--timeout SECS]" >&2
    exit 1
fi

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log() { echo "[gap-run-now] $*"; }

# ── Validate gap ──────────────────────────────────────────────────────────────
log "Validating $GAP_ID..."

# Check gap exists and is open
_gap_info=$(chump gap show "$GAP_ID" 2>/dev/null || true)
if [[ -z "$_gap_info" ]]; then
    log "ERROR: gap $GAP_ID not found in registry" >&2
    exit 1
fi

_status=$(printf '%s' "$_gap_info" | grep '^\s*status:' | head -1 | awk '{print $2}')
if [[ "$_status" != "open" ]]; then
    log "ERROR: gap $GAP_ID has status='$_status' (must be open)" >&2
    exit 1
fi

# Check gap is not already claimed (look for active lease)
_gap_lower=$(printf '%s' "$GAP_ID" | tr '[:upper:]' '[:lower:]')
_lease=$(ls "$REPO_ROOT/.chump-locks/claim-${_gap_lower}"*.json 2>/dev/null | head -1 || true)
if [[ -n "$_lease" ]]; then
    _session=$(python3 -c "import json; d=json.load(open('$_lease')); print(d.get('session_id','?'))" 2>/dev/null || echo "?")
    log "ERROR: gap $GAP_ID is already claimed by session $_session" >&2
    exit 1
fi

log "$GAP_ID is open and unclaimed — OK"

# ── Emit intent event ─────────────────────────────────────────────────────────
_model="${MODEL_OVERRIDE:-${FLEET_MODEL:-sonnet}}"
_timeout="${TIMEOUT_OVERRIDE:-${FLEET_TIMEOUT_S:-1800}}"

_ev=$(printf '{"ts":"%s","kind":"gap_run_now_triggered","gap_id":"%s","model":"%s","timeout_s":%s,"dry_run":%s}' \
    "$(_ts)" "$GAP_ID" "$_model" "$_timeout" "$([[ $DRY_RUN -eq 1 ]] && echo 'true' || echo 'false')")

mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
printf '%s\n' "$_ev" >> "$AMBIENT" 2>/dev/null || true
log "Emitted kind=gap_run_now_triggered"

# ── Dispatch ──────────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: would invoke worker with GAP_ID=$GAP_ID model=$_model timeout=${_timeout}s"
    log "Command: FLEET_MODEL=$_model FLEET_TIMEOUT_S=$_timeout GAP_ID=$GAP_ID bash $WORKER"
    exit 0
fi

if [[ ! -x "$WORKER" ]]; then
    log "ERROR: worker not found at $WORKER" >&2
    exit 1
fi

log "Invoking worker for $GAP_ID (model=$_model, timeout=${_timeout}s)..."
FLEET_MODEL="$_model" \
FLEET_TIMEOUT_S="$_timeout" \
GAP_ID="$GAP_ID" \
REPO_ROOT="$REPO_ROOT" \
    bash "$WORKER" || {
        log "Worker exited non-zero for $GAP_ID"
        exit 2
    }

log "Worker completed for $GAP_ID"
