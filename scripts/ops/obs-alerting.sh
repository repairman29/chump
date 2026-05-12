#!/usr/bin/env bash
# scripts/ops/obs-alerting.sh — INFRA-679: wire observability to alerting
#
# Evaluates 2 alert conditions and routes them to ambient.jsonl AND
# to the operator via webhook (Discord/Telegram/generic HTTP POST).
#
# Alert conditions:
#   A. cascade_near_cap: ≥3 provider slots at >80% of daily RPD limit
#   B. cost_budget_breach: daily Anthropic spend > CHUMP_DAILY_COST_CAP_USD
#
# Usage:
#   obs-alerting.sh [--dry-run] [--json]
#
# Env overrides (also used for testing):
#   CHUMP_REPO              override repo root
#   CHUMP_AMBIENT_OVERRIDE  override ambient.jsonl path
#   CHUMP_ALERT_WEBHOOK     POST alerts here (Discord/Telegram/generic)
#   CHUMP_DAILY_COST_CAP_USD  daily spend cap in USD (default: read from daily-cost.json budget field)
#   CHUMP_PROVIDER_N_RPD    per-slot RPD limit (N = 1..9)
#   CHUMP_PROVIDER_USAGE_FILE  override path to per-slot usage JSON (default: .chump/provider-usage.json)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${CHUMP_REPO:-$(cd "$SCRIPT_DIR/../.." && git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT="${CHUMP_AMBIENT_OVERRIDE:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
USAGE_FILE="${CHUMP_PROVIDER_USAGE_FILE:-$REPO_ROOT/.chump/provider-usage.json}"
COST_FILE="$REPO_ROOT/.chump/daily-cost.json"

DRY=0
JSON=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1
[[ "${1:-}" == "--json" ]] && JSON=1
[[ "${2:-}" == "--dry-run" ]] && DRY=1
[[ "${2:-}" == "--json" ]] && JSON=1

ts()  { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { [[ "$JSON" -eq 0 ]] && printf '[obs-alerting %s] %s\n' "$(ts)" "$*" || true; }

ALERTS_FIRED=0

emit_alert() {
    local kind="$1"; shift
    local fields="$*"
    local ts_val; ts_val="$(ts)"
    local payload; payload="$(printf '{"ts":"%s","kind":"%s",%s}' "$ts_val" "$kind" "$fields")"

    if [[ "$DRY" -eq 0 ]]; then
        printf '%s\n' "$payload" >> "$AMBIENT" 2>/dev/null || true
    fi

    if [[ "$JSON" -eq 1 ]]; then
        printf '%s\n' "$payload"
    else
        log "ALERT $kind | $fields"
    fi

    # Route to operator webhook if configured.
    local webhook="${CHUMP_ALERT_WEBHOOK:-}"
    if [[ -n "$webhook" && "$DRY" -eq 0 ]]; then
        curl -s -f -X POST "$webhook" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            --max-time 10 \
            >/dev/null 2>&1 || log "WARN: webhook POST to $webhook failed"
    fi

    ALERTS_FIRED=$((ALERTS_FIRED + 1))
}

# ── Condition A: cascade_near_cap ─────────────────────────────────────────────
check_cascade() {
    [[ -f "$USAGE_FILE" ]] || { log "no provider-usage.json at $USAGE_FILE — skip cascade check"; return; }

    local near_cap_slots=0
    local slot_list=""

    for n in 1 2 3 4 5 6 7 8 9; do
        local rpd_var="CHUMP_PROVIDER_${n}_RPD"
        local rpd_limit="${!rpd_var:-}"
        [[ -z "$rpd_limit" || "$rpd_limit" -eq 0 ]] && continue

        # Read today's call count for this slot from usage file.
        local used
        used=$(python3 -c "
import json, sys
try:
    d = json.load(open('$USAGE_FILE'))
    print(d.get('$n', d.get(${n}, 0)))
except Exception: print(0)
" 2>/dev/null)
        used="${used:-0}"

        local pct=$(( used * 100 / rpd_limit ))
        if [[ "$pct" -ge 80 ]]; then
            near_cap_slots=$((near_cap_slots + 1))
            slot_list="${slot_list}slot${n}=${pct}% "
        fi
    done

    if [[ "$near_cap_slots" -ge 3 ]]; then
        emit_alert "cascade_near_cap" \
            "\"near_cap_slots\":$near_cap_slots,\"detail\":\"$(printf '%s' "$slot_list" | sed 's/"/\\"/g')\",\"threshold_pct\":80"
    else
        log "cascade OK ($near_cap_slots slots at >80% RPD, threshold: 3)"
    fi
}

# ── Condition B: cost_budget_breach ───────────────────────────────────────────
check_cost() {
    [[ -f "$COST_FILE" ]] || { log "no daily-cost.json at $COST_FILE — skip cost check"; return; }

    local raw; raw=$(python3 -c "
import json
d = json.load(open('$COST_FILE'))
spent = float(d.get('spent_usd', 0))
budget = float(d.get('budget_usd', 0))
cap_env = '${CHUMP_DAILY_COST_CAP_USD:-}'
cap = float(cap_env) if cap_env else budget
print(spent, cap)
" 2>/dev/null) || return

    local spent cap
    read -r spent cap <<< "$raw"
    if [[ -z "$cap" || "$cap" == "0" ]]; then
        log "no cost cap configured — skip cost check"
        return
    fi

    # Use python3 for float comparison.
    local breached
    breached=$(python3 -c "print('yes' if $spent > $cap else 'no')" 2>/dev/null)
    if [[ "$breached" == "yes" ]]; then
        emit_alert "cost_budget_breach" \
            "\"spent_usd\":$spent,\"cap_usd\":$cap,\"pct\":$(python3 -c "print(round($spent/$cap*100,1))")"
    else
        log "cost OK (${spent}/${cap} USD)"
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────────
check_cascade
check_cost

if [[ "$JSON" -eq 0 ]]; then
    if [[ "$ALERTS_FIRED" -eq 0 ]]; then
        log "no alerts fired"
    else
        log "$ALERTS_FIRED alert(s) fired"
    fi
fi
