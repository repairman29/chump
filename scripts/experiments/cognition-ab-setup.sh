#!/usr/bin/env bash
# cognition-ab-setup.sh — META-045
# Launches one cell of the cognition-stack A/B experiment.
#
# Cell A (cognition ON):  CHUMP_LESSONS_AT_SPAWN_N=5 + CHUMP_LESSONS_EMBEDDING=1
# Cell B (cognition OFF): CHUMP_LESSONS_AT_SPAWN_N=0 + CHUMP_LESSONS_EMBEDDING unset
#
# Each cell runs in its own tmux session with a dedicated ambient log so the
# report script can compare them directly without session-ID overlap.
#
# Usage:
#   scripts/experiments/cognition-ab-setup.sh --cell A
#   scripts/experiments/cognition-ab-setup.sh --cell B
#   scripts/experiments/cognition-ab-setup.sh --cell A --fleet-size 2 --dry-run
#
# After both cells have run for ~24 h, generate the comparison:
#   scripts/experiments/cognition-ab-report.sh
#
# Environment:
#   META045_RUN_TAG   optional run identifier (default: date-based)
#   META045_LOG_DIR   directory for per-cell ambient logs (default: .chump-locks/meta045)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CELL=""
FLEET_SIZE="${FLEET_SIZE:-2}"
DRY_RUN=0
RUN_TAG="${META045_RUN_TAG:-$(date -u +%Y%m%d-%H%M%S)}"
LOG_DIR="${META045_LOG_DIR:-$REPO_ROOT/.chump-locks/meta045}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cell)        CELL="$2"; shift 2 ;;
        --fleet-size)  FLEET_SIZE="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=1; shift ;;
        --help|-h)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "cognition-ab-setup.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ "$CELL" == "A" || "$CELL" == "B" ]] \
    || { echo "ERROR: --cell A or --cell B required" >&2; exit 2; }

mkdir -p "$LOG_DIR"

AMBIENT_LOG="$LOG_DIR/cell-${CELL}-${RUN_TAG}.jsonl"
TMUX_SESSION="chump-ab-$(echo "$CELL" | tr '[:upper:]' '[:lower:]')"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Configure cell environment ────────────────────────────────────────────────

if [[ "$CELL" == "A" ]]; then
    export CHUMP_LESSONS_AT_SPAWN_N=5
    export CHUMP_LESSONS_EMBEDDING=1
    CELL_LABEL="cognition-ON (lessons=5, embedding=1)"
else
    export CHUMP_LESSONS_AT_SPAWN_N=0
    unset CHUMP_LESSONS_EMBEDDING 2>/dev/null || true
    CELL_LABEL="cognition-OFF (lessons=0, embedding=0)"
fi

export FLEET_SESSION="$TMUX_SESSION"
export FLEET_SIZE="$FLEET_SIZE"
export CHUMP_AMBIENT_LOG="$AMBIENT_LOG"
export META045_AB_CELL="$CELL"
export META045_RUN_TAG="$RUN_TAG"

echo "[cognition-ab] cell=$CELL  config=$CELL_LABEL"
echo "[cognition-ab] ambient_log=$AMBIENT_LOG"
echo "[cognition-ab] fleet_session=$TMUX_SESSION  fleet_size=$FLEET_SIZE"

# ── Emit run-start event ─────────────────────────────────────────────────────

printf '{"ts":"%s","kind":"cognition_ab_run_start","cell":"%s","run_tag":"%s","lessons_at_spawn_n":%d,"embedding_enabled":%s,"fleet_size":%d}\n' \
    "$(ts)" "$CELL" "$RUN_TAG" "${CHUMP_LESSONS_AT_SPAWN_N}" \
    "$([ "${CHUMP_LESSONS_EMBEDDING:-0}" = "1" ] && echo true || echo false)" \
    "$FLEET_SIZE" \
    >> "$AMBIENT_LOG"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[cognition-ab] DRY-RUN — would launch fleet:"
    echo "  FLEET_SESSION=$TMUX_SESSION FLEET_SIZE=$FLEET_SIZE \\"
    echo "  CHUMP_AMBIENT_LOG=$AMBIENT_LOG \\"
    echo "  CHUMP_LESSONS_AT_SPAWN_N=${CHUMP_LESSONS_AT_SPAWN_N} \\"
    echo "  CHUMP_LESSONS_EMBEDDING=${CHUMP_LESSONS_EMBEDDING:-0} \\"
    echo "  bash $REPO_ROOT/scripts/dispatch/run-fleet.sh"
    exit 0
fi

# ── Launch fleet ──────────────────────────────────────────────────────────────

echo "[cognition-ab] launching fleet for cell $CELL…"
bash "$REPO_ROOT/scripts/dispatch/run-fleet.sh"
