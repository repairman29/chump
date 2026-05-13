#!/usr/bin/env bash
# gate-emit.sh — CREDIBLE-048
#
# Sourceable library: emit gate_check_start / gate_check_result ambient events
# and GitHub Actions ::notice:: annotations from CI gate scripts.
#
# Usage (in any gate script):
#   source "$(dirname "$0")/lib/gate-emit.sh"
#   gate_emit_start "CREDIBLE-026" "$*"
#   ... gate logic ...
#   gate_emit_result "CREDIBLE-026" "pass" "" ""
#   gate_emit_result "CREDIBLE-026" "fail" "scope-violation" "PR title chore(gaps) but touched src/"
#   gate_emit_result "CREDIBLE-026" "bypassed" "" "CHUMP_PR_SCOPE_CHECK=0"
#   gate_emit_result "CREDIBLE-026" "skipped" "" "no PR context"
#
# Environment:
#   CHUMP_GATE_TELEMETRY=0   suppress all gate event emission
#   CHUMP_AMBIENT_LOG        path to ambient.jsonl (default: .chump-locks/ambient.jsonl)

_GATE_EMIT_LOADED=1

_gate_ambient_path() {
    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    echo "${CHUMP_AMBIENT_LOG:-${repo_root}/.chump-locks/ambient.jsonl}"
}

# gate_emit_start <gate_name> [<invocation_args>]
gate_emit_start() {
    [[ "${CHUMP_GATE_TELEMETRY:-1}" == "0" ]] && return 0
    local gate_name="$1"
    local args="${2:-}"
    local ts ambient pr_or_branch
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    pr_or_branch="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')}}"
    ambient="$(_gate_ambient_path)"
    mkdir -p "$(dirname "$ambient")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"gate_check_start","gate":"%s","pr_or_branch":"%s","args":"%s"}\n' \
        "$ts" "$gate_name" "$pr_or_branch" "${args//\"/\\\"}" \
        >> "$ambient" 2>/dev/null || true
}

# gate_emit_result <gate_name> <outcome> [<rule_fired>] [<evidence>]
#   outcome: pass | fail | bypassed | skipped
gate_emit_result() {
    [[ "${CHUMP_GATE_TELEMETRY:-1}" == "0" ]] && return 0
    local gate_name="$1"
    local outcome="$2"
    local rule_fired="${3:-}"
    local evidence="${4:-}"
    local ts ambient pr_or_branch
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    pr_or_branch="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')}}"
    ambient="$(_gate_ambient_path)"
    mkdir -p "$(dirname "$ambient")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"gate_check_result","gate":"%s","outcome":"%s","rule_fired":"%s","evidence":"%s","pr_or_branch":"%s"}\n' \
        "$ts" "$gate_name" "$outcome" "$rule_fired" "${evidence//\"/\\\"}" "$pr_or_branch" \
        >> "$ambient" 2>/dev/null || true
    # GitHub Actions notice annotation
    if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
        local bypass_info=""
        [[ "$outcome" == "bypassed" ]] && bypass_info="; bypass: ${evidence}"
        echo "::notice title=Gate ${gate_name}::${outcome}$([ -n "$rule_fired" ] && echo "; rule: $rule_fired")${bypass_info}"
    fi
}
