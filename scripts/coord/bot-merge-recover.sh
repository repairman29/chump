#!/usr/bin/env bash
#
# bot-merge-recover.sh — Crash recovery helper for bot-merge.sh.
#
# Reads the append-only steps file written by bot-merge.sh (INFRA-1035) and
# prints a human-readable recovery summary: last completed step, the step that
# was in progress when the crash happened, and a suggestion for where to resume.
#
# Usage:
#   scripts/coord/bot-merge-recover.sh [--steps-file PATH] [--all]
#   scripts/coord/bot-merge-recover.sh            # auto-detect newest .steps file
#   scripts/coord/bot-merge-recover.sh --all      # summarize all steps files
#
# Exit codes:
#   0  clean exit detected (last entry was done or no crash)
#   1  crash detected (start without matching done)
#   2  no steps file found

set -euo pipefail

STEPS_FILE=""
SHOW_ALL=0
LOCK_DIR=".chump-locks"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --steps-file) STEPS_FILE="$2"; shift 2 ;;
        --all)        SHOW_ALL=1; shift ;;
        --lock-dir)   LOCK_DIR="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

summarize_steps_file() {
    local sf="$1"
    if [[ ! -f "$sf" ]]; then
        echo "steps file not found: $sf" >&2
        return 2
    fi

    local last_done="" last_start="" crashed=0 step transition

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        transition="$(echo "$line" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("transition",""))' 2>/dev/null || true)"
        step="$(echo "$line" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("step",""))' 2>/dev/null || true)"
        case "$transition" in
            start) last_start="$step" ;;
            done)  last_done="$step"; last_start="" ;;
            error) crashed=1; last_start="$step" ;;
        esac
    done < "$sf"

    echo "  Steps file: $(basename "$sf")"
    if [[ -n "$last_done" ]]; then
        echo "  Last completed step: $last_done"
    else
        echo "  Last completed step: (none)"
    fi

    if [[ $crashed -eq 1 ]] || [[ -n "$last_start" ]]; then
        echo "  Crashed during:      ${last_start:-unknown}"
        echo "  Recovery suggestion: re-run bot-merge.sh from the '${last_done:-beginning}' step"
        return 1
    else
        echo "  Status: clean exit"
        return 0
    fi
}

if [[ $SHOW_ALL -eq 1 ]]; then
    found=0
    for sf in "${LOCK_DIR}"/bot-merge-*.steps; do
        [[ -f "$sf" ]] || continue
        echo "=== $(basename "$sf") ==="
        summarize_steps_file "$sf" || true
        found=1
    done
    [[ $found -eq 0 ]] && { echo "no .steps files in ${LOCK_DIR}" >&2; exit 2; }
    exit 0
fi

if [[ -z "$STEPS_FILE" ]]; then
    # Auto-detect: pick the newest .steps file
    newest=""
    for sf in "${LOCK_DIR}"/bot-merge-*.steps; do
        [[ -f "$sf" ]] || continue
        if [[ -z "$newest" ]] || [[ "$sf" -nt "$newest" ]]; then
            newest="$sf"
        fi
    done
    if [[ -z "$newest" ]]; then
        echo "no bot-merge .steps file found in ${LOCK_DIR}/" >&2
        echo "hint: run bot-merge.sh first, or pass --steps-file explicitly" >&2
        exit 2
    fi
    STEPS_FILE="$newest"
fi

summarize_steps_file "$STEPS_FILE"
