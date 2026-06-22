#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Pillar balance analyzer: counts pickable gaps per pillar, emits alerts to
# ambient.jsonl, exits non-zero if any alert fired.
#
# "Pickable" = P0|P1, effort xs|s|m, no ⚠ marker (vague AC or blocked deps).
#
# Alert kinds emitted:
#   pillar_balance_alert      — pillar count < PILLAR_FLOOR (default 2)
#   pillar_balance_overweight — pillar count > 50% of total pickable pool
#
# Env overrides:
#   CHUMP_BIN               path to chump binary (default: chump in PATH)
#   CHUMP_AMBIENT_OVERRIDE  override ambient.jsonl path
#   CHUMP_REPO              override repo root
#   PILLAR_FLOOR            minimum pickable per pillar (default: 2)
#
# Usage:
#   scripts/ops/pillar-balance-check.sh [--dry-run] [--json] [--quiet]
#
# Bash 3.2 compatible (macOS /bin/bash). No declare -A, mapfile, readarray.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${CHUMP_REPO:-$(cd "$SCRIPT_DIR/../.." && git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT="${CHUMP_AMBIENT_OVERRIDE:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
BIN="${CHUMP_BIN:-chump}"
FLOOR="${PILLAR_FLOOR:-2}"
OVERWEIGHT_PCT=50

DRY=0
JSON=0
QUIET=0
for arg in "${@:-}"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --json)    JSON=1 ;;
        --quiet)   QUIET=1 ;;
    esac
done

ts()  { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { [[ "$QUIET" -eq 0 && "$JSON" -eq 0 ]] && printf '[pillar-balance %s] %s\n' "$(ts)" "$*" >&2 || true; }

ALERTS_FIRED=0

emit_event() {
    local kind="$1" fields="$2"
    local ts_val; ts_val="$(ts)"
    local payload; payload="{\"ts\":\"${ts_val}\",\"kind\":\"${kind}\",${fields}}"

    if [[ "$DRY" -eq 0 ]]; then
        mkdir -p "$(dirname "$AMBIENT")"
        printf '%s\n' "$payload" >> "$AMBIENT" 2>/dev/null || true
    fi

    if [[ "$JSON" -eq 1 ]]; then
        printf '%s\n' "$payload"
    else
        log "ALERT $kind | $fields"
    fi

    ALERTS_FIRED=$(( ALERTS_FIRED + 1 ))
}

# ── Fetch open gap list ────────────────────────────────────────────────────────
# Use CHUMP_BIN so tests can inject a fixture binary without relying on PATH.
if ! command -v "$BIN" &>/dev/null; then
    log "chump binary not found ($BIN) — skipping pillar balance check"
    exit 0
fi

GAP_LIST="$("$BIN" gap list --status open 2>/dev/null)" || GAP_LIST=""

# ── Count pickable per pillar (Bash 3.2 compat: individual vars, no declare -A)
# Pickable = P0|P1, effort xs/s/m, no ⚠ (vague AC or blocked dep).
count_for_pillar() {
    local pillar="$1"
    printf '%s\n' "$GAP_LIST" \
        | grep -i "${pillar}:" \
        | grep -E "\(P[01]/(xs|s|m)\)" \
        | grep -v "⚠" \
        | wc -l \
        | tr -d ' '
}

cnt_EFFECTIVE="$(count_for_pillar EFFECTIVE)"
cnt_EFFECTIVE="${cnt_EFFECTIVE:-0}"

cnt_CREDIBLE="$(count_for_pillar CREDIBLE)"
cnt_CREDIBLE="${cnt_CREDIBLE:-0}"

cnt_RESILIENT="$(count_for_pillar RESILIENT)"
cnt_RESILIENT="${cnt_RESILIENT:-0}"

cnt_ZEROWASTE="$(count_for_pillar ZERO-WASTE)"
cnt_ZEROWASTE="${cnt_ZEROWASTE:-0}"

TOTAL=$(( cnt_EFFECTIVE + cnt_CREDIBLE + cnt_RESILIENT + cnt_ZEROWASTE ))

log "pillar counts: EFFECTIVE=$cnt_EFFECTIVE CREDIBLE=$cnt_CREDIBLE RESILIENT=$cnt_RESILIENT ZERO-WASTE=$cnt_ZEROWASTE total=$TOTAL"

# ── Per-pillar checks ──────────────────────────────────────────────────────────
check_pillar() {
    local pillar="$1" count="$2"

    # Under-fed alert.
    if [[ "$count" -lt "$FLOOR" ]]; then
        emit_event "pillar_balance_alert" \
            "\"pillar\":\"${pillar}\",\"count\":${count},\"floor\":${FLOOR}"
    fi

    # Overweight alert (only meaningful when total > 0).
    if [[ "$TOTAL" -gt 0 ]]; then
        local pct=$(( count * 100 / TOTAL ))
        if [[ "$pct" -gt "$OVERWEIGHT_PCT" ]]; then
            emit_event "pillar_balance_overweight" \
                "\"pillar\":\"${pillar}\",\"count\":${count},\"pct\":${pct}"
        fi
    fi
}

check_pillar "EFFECTIVE"  "$cnt_EFFECTIVE"
check_pillar "CREDIBLE"   "$cnt_CREDIBLE"
check_pillar "RESILIENT"  "$cnt_RESILIENT"
check_pillar "ZERO-WASTE" "$cnt_ZEROWASTE"

# ── Human-readable summary (non-JSON mode) ────────────────────────────────────
if [[ "$JSON" -eq 0 && "$QUIET" -eq 0 ]]; then
    printf '\n=== pillar-balance-check (INFRA-902) ===\n'
    printf '  EFFECTIVE : %d\n'  "$cnt_EFFECTIVE"
    printf '  CREDIBLE  : %d\n'  "$cnt_CREDIBLE"
    printf '  RESILIENT : %d\n'  "$cnt_RESILIENT"
    printf '  ZERO-WASTE: %d\n'  "$cnt_ZEROWASTE"
    printf '  total     : %d\n'  "$TOTAL"
    if [[ "$ALERTS_FIRED" -gt 0 ]]; then
        printf '  status    : ALERTS_FIRED=%d\n' "$ALERTS_FIRED"
    else
        printf '  status    : OK (all pillars healthy)\n'
    fi
    printf '\n'
fi

[[ "$ALERTS_FIRED" -eq 0 ]]
