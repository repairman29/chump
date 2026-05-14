#!/usr/bin/env bash
# api-rate-limit-gate.sh — INFRA-1055: circuit breaker for GitHub API quota.
#
# Thresholds (from AC):
#   REST core:  gate opens at 80% consumed → ≤ 20% remaining (≤ 1000/5000)
#   GraphQL:    gate opens at 50% consumed → ≤ 50% remaining (≤ 2500/5000)
#
# Exposes three functions meant to be sourced by bot-merge.sh, fleet-status.sh:
#
#   rate_limit_snapshot [--ambient <path>]
#     Queries /rate_limit REST endpoint (one REST call, no GraphQL quota).
#     Sets: RL_REST_REMAINING, RL_REST_LIMIT, RL_REST_PCT (remaining%)
#           RL_GQL_REMAINING,  RL_GQL_LIMIT,  RL_GQL_PCT  (remaining%)
#     Returns 0 always (callers handle missing data via fallback defaults).
#
#   rate_limit_gate <phase> [--source <script>] [--ambient <path>]
#     Calls rate_limit_snapshot, evaluates thresholds, emits ambient events.
#     Returns:
#       0 — all quotas healthy; proceed normally
#       1 — approaching limit; skip optional work, proceed for critical
#       2 — exhausted; skip this phase entirely (emit gate_skipped)
#
#   gate_skip_phase <phase> <reason> [--source <script>] [--ambient <path>]
#     Emits kind=gate_skipped to ambient.jsonl for a named phase.
#     Caller is responsible for actually skipping the work.
#
# Bypass: CHUMP_RL_GATE_SKIP=1 disables all checks (dry-run, mocks, offline).
# Override thresholds via:
#   CHUMP_RL_REST_WARN_PCT   (default 20 — warn below this remaining%)
#   CHUMP_RL_GQL_WARN_PCT    (default 50 — warn below this remaining%)

# ── exported state (populated by rate_limit_snapshot) ────────────────────────
RL_REST_REMAINING=0
RL_REST_LIMIT=5000
RL_REST_PCT=100
RL_GQL_REMAINING=0
RL_GQL_LIMIT=5000
RL_GQL_PCT=100

_rl_ambient() {
    printf '%s' "${1:-${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}}"
}

rate_limit_snapshot() {
    local ambient=""
    while [[ $# -gt 0 ]]; do
        case "$1" in --ambient) ambient="$2"; shift 2 ;; *) shift ;; esac
    done
    ambient="$(_rl_ambient "$ambient")"

    [[ "${CHUMP_RL_GATE_SKIP:-0}" == "1" ]] && return 0

    local raw
    raw=$(gh api /rate_limit 2>/dev/null || echo "")
    [[ -z "$raw" ]] && return 0

    RL_REST_REMAINING=$(printf '%s' "$raw" | python3 -c \
        "import json,sys; d=json.load(sys.stdin); print(d['resources']['core']['remaining'])" 2>/dev/null || echo 0)
    RL_REST_LIMIT=$(printf '%s' "$raw" | python3 -c \
        "import json,sys; d=json.load(sys.stdin); print(d['resources']['core']['limit'])" 2>/dev/null || echo 5000)
    RL_GQL_REMAINING=$(printf '%s' "$raw" | python3 -c \
        "import json,sys; d=json.load(sys.stdin); print(d['resources']['graphql']['remaining'])" 2>/dev/null || echo 0)
    RL_GQL_LIMIT=$(printf '%s' "$raw" | python3 -c \
        "import json,sys; d=json.load(sys.stdin); print(d['resources']['graphql']['limit'])" 2>/dev/null || echo 5000)

    if [[ "$RL_REST_LIMIT" -gt 0 ]]; then
        RL_REST_PCT=$(( RL_REST_REMAINING * 100 / RL_REST_LIMIT ))
    fi
    if [[ "$RL_GQL_LIMIT" -gt 0 ]]; then
        RL_GQL_PCT=$(( RL_GQL_REMAINING * 100 / RL_GQL_LIMIT ))
    fi

    return 0
}

rate_limit_gate() {
    local phase="${1:-unknown}"; shift || true
    local source_script="bot-merge.sh" ambient=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source)  source_script="$2"; shift 2 ;;
            --ambient) ambient="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    ambient="$(_rl_ambient "$ambient")"

    [[ "${CHUMP_RL_GATE_SKIP:-0}" == "1" ]] && return 0

    rate_limit_snapshot --ambient "$ambient"

    local rest_warn_pct="${CHUMP_RL_REST_WARN_PCT:-20}"
    local gql_warn_pct="${CHUMP_RL_GQL_WARN_PCT:-50}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local worst=0

    # REST quota check
    if [[ "$RL_REST_REMAINING" -eq 0 ]]; then
        printf '{"ts":"%s","kind":"rate_limit_exhausted","source":"%s","phase":"%s","api":"rest","remaining":0,"limit":%d}\n' \
            "$ts" "$source_script" "$phase" "$RL_REST_LIMIT" >> "$ambient" 2>/dev/null || true
        printf '[rate-limit-gate] REST quota EXHAUSTED (0/%d) — skipping phase: %s\n' "$RL_REST_LIMIT" "$phase" >&2
        gate_skip_phase "$phase" "rest_exhausted" --source "$source_script" --ambient "$ambient"
        return 2
    elif [[ "$RL_REST_PCT" -le "$rest_warn_pct" ]]; then
        printf '{"ts":"%s","kind":"rate_limit_approaching","source":"%s","phase":"%s","api":"rest","remaining":%d,"limit":%d,"pct_remaining":%d}\n' \
            "$ts" "$source_script" "$phase" "$RL_REST_REMAINING" "$RL_REST_LIMIT" "$RL_REST_PCT" \
            >> "$ambient" 2>/dev/null || true
        printf '[rate-limit-gate] WARN: REST quota low (%d/%d = %d%% remaining) — degraded mode for phase: %s\n' \
            "$RL_REST_REMAINING" "$RL_REST_LIMIT" "$RL_REST_PCT" "$phase" >&2
        worst=1
    fi

    # GraphQL quota check
    if [[ "$RL_GQL_REMAINING" -eq 0 ]]; then
        printf '{"ts":"%s","kind":"rate_limit_exhausted","source":"%s","phase":"%s","api":"graphql","remaining":0,"limit":%d}\n' \
            "$ts" "$source_script" "$phase" "$RL_GQL_LIMIT" >> "$ambient" 2>/dev/null || true
        printf '[rate-limit-gate] GraphQL quota EXHAUSTED (0/%d) — GraphQL-dependent phases will use REST fallback\n' "$RL_GQL_LIMIT" >&2
        [[ $worst -lt 1 ]] && worst=1
    elif [[ "$RL_GQL_PCT" -le "$gql_warn_pct" ]]; then
        printf '{"ts":"%s","kind":"rate_limit_approaching","source":"%s","phase":"%s","api":"graphql","remaining":%d,"limit":%d,"pct_remaining":%d}\n' \
            "$ts" "$source_script" "$phase" "$RL_GQL_REMAINING" "$RL_GQL_LIMIT" "$RL_GQL_PCT" \
            >> "$ambient" 2>/dev/null || true
        printf '[rate-limit-gate] WARN: GraphQL quota low (%d/%d = %d%% remaining) — skipping GraphQL-optional work\n' \
            "$RL_GQL_REMAINING" "$RL_GQL_LIMIT" "$RL_GQL_PCT" >&2
        [[ $worst -lt 1 ]] && worst=1
    fi

    return $worst
}

gate_skip_phase() {
    local phase="${1:-unknown}" reason="${2:-rate_limited}"; shift 2 || true
    local source_script="bot-merge.sh" ambient=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source)  source_script="$2"; shift 2 ;;
            --ambient) ambient="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    ambient="$(_rl_ambient "$ambient")"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"gate_skipped","source":"%s","phase":"%s","reason":"%s","rest_remaining":%d,"gql_remaining":%d}\n' \
        "$ts" "$source_script" "$phase" "$reason" \
        "${RL_REST_REMAINING:-0}" "${RL_GQL_REMAINING:-0}" \
        >> "$ambient" 2>/dev/null || true
}
