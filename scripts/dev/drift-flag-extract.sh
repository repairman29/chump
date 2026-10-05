#!/usr/bin/env bash
# drift-flag-extract.sh — CREDIBLE-569 (CREDIBLE-222 slice)
#
# Pulls the latest DRIFT-flag findings for this repo from almanac's
# `comprehend --findings-json` organ sweep (CONFIG organ, EFFECTIVE-398) and
# stores the raw JSON for downstream triage (CREDIBLE-222: separating real
# incoherence from parser noise). This script only extracts + counts; it
# does not normalize or triage — that's CREDIBLE-222 proper.
#
# Usage:
#   scripts/dev/drift-flag-extract.sh [--repo <path>] [--out <file>] [--json]
#
# Env overrides (mirrors scripts/health/almanac_health.sh):
#   ALMANAC_BIN   default: $HOME/Projects/almanac/target/release/almanac
#
# Exit codes:
#   0 — extraction succeeded (flags_retrieved may legitimately be 0)
#   1 — almanac binary not found/executable
#   2 — almanac comprehend call failed or output could not be written

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALMANAC_BIN="${ALMANAC_BIN:-$HOME/Projects/almanac/target/release/almanac}"
OUT_FILE=""
JSON_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --out) OUT_FILE="$2"; shift 2 ;;
        --json) JSON_MODE=true; shift ;;
        -h|--help)
            sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "drift-flag-extract: unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$OUT_FILE" ]]; then
    OUT_FILE="$(mktemp -t drift-flags-XXXXXX.json)"
fi

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(_ts)] drift-flag-extract: $*" >&2; }

if [[ ! -x "$ALMANAC_BIN" ]]; then
    log "almanac binary not found/executable at $ALMANAC_BIN — set ALMANAC_BIN to override"
    exit 1
fi

log "pulling drift-flag findings for repo=$REPO"
if ! raw_output="$("$ALMANAC_BIN" comprehend --repo "$REPO" --findings-json 2>&1)"; then
    log "almanac comprehend failed: $raw_output"
    exit 2
fi

if ! printf '%s\n' "$raw_output" > "$OUT_FILE"; then
    log "failed to write raw output to $OUT_FILE"
    exit 2
fi

if command -v jq >/dev/null 2>&1 && jq -e . >/dev/null 2>&1 <<<"$raw_output"; then
    flag_count="$(jq '[.. | objects | select((.kind? // .category? // "") | ascii_upcase == "DRIFT")] | length' <<<"$raw_output" 2>/dev/null || echo 0)"
else
    flag_count="$(grep -o '"kind"[[:space:]]*:[[:space:]]*"DRIFT"' <<<"$raw_output" | wc -l | tr -d ' ')"
fi
[[ "$flag_count" =~ ^[0-9]+$ ]] || flag_count=0

log "retrieved $flag_count drift flag(s), raw data stored at $OUT_FILE"

if [[ "$JSON_MODE" == true ]]; then
    printf '{"flags_retrieved":%d,"out_file":"%s"}\n' "$flag_count" "$OUT_FILE"
fi

exit 0
