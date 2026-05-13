#!/usr/bin/env bash
# scripts/coord/lib/github.sh — INFRA-999
#
# Wrappers around `gh` that record every call to .chump-locks/ambient.jsonl
# as kind=github_api_call so we can rank which scripts burn which rate-limit
# bucket (core REST vs GraphQL) before deciding which polling to convert to
# webhooks (INFRA-1000).
#
# Two entry points:
#
#   chump_gh <gh-args...>
#       Time + run gh, then emit one github_api_call event.
#
#   chump_gh_record <api_tag> <used_ms> <rc>
#       Record-only: caller already ran gh themselves (e.g. through a
#       timeout/heartbeat wrapper) and just wants the event recorded.
#
# Emitted JSON line shape:
#   {"ts":"…","kind":"github_api_call","script":"<basename>","api":"pr merge",
#    "remaining_core":N,"remaining_graphql":N,"used_ms":N,"rc":N}
#
# Caller can override the recorded script name by exporting CHUMP_GH_SCRIPT
# before the call; default is the basename of the script that sourced this
# file. Set CHUMP_GH_SILENT=1 to skip emission (test mocks, recursive use).
#
# Cost note: reading remaining via `gh api rate_limit` does NOT count against
# either bucket per GitHub docs, so we pay no per-call premium.

[[ -n "${_CHUMP_GH_LIB_LOADED:-}" ]] && return 0
_CHUMP_GH_LIB_LOADED=1

_chump_gh_ambient_path() {
    if [[ -n "${CHUMP_AMBIENT_OVERRIDE:-}" ]]; then
        printf '%s' "$CHUMP_AMBIENT_OVERRIDE"
        return
    fi
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    printf '%s/.chump-locks/ambient.jsonl' "$root"
}

# Pick a 1-2 token api tag from the gh argv.
#   pr merge 123 --auto    → "pr merge"
#   pr view --json state   → "pr view"
#   api /rate_limit        → "api"
#   run watch 42           → "run watch"
chump_gh_api_tag() {
    local first="${1:-?}" second="${2:-}"
    if [[ -z "$second" || "$second" == -* || "$second" == /* ]]; then
        printf '%s' "$first"
        return
    fi
    printf '%s %s' "$first" "$second"
}

# Read remaining core+graphql via `gh api rate_limit`. Returns "core graphql".
# On failure returns "-1 -1" rather than blocking the wrapped call.
_chump_gh_rate_remaining() {
    local out
    out="$(gh api rate_limit --jq '"\(.resources.core.remaining) \(.resources.graphql.remaining)"' 2>/dev/null || true)"
    if [[ -z "$out" ]]; then
        printf '%s' "-1 -1"
        return
    fi
    printf '%s' "$out"
}

# chump_gh_record API_TAG USED_MS RC [SCRIPT_OVERRIDE]
chump_gh_record() {
    [[ "${CHUMP_GH_SILENT:-0}" == "1" ]] && return 0
    local api_tag="${1:-?}" used_ms="${2:-0}" rc="${3:-0}" script_tag
    script_tag="${4:-${CHUMP_GH_SCRIPT:-$(basename "${BASH_SOURCE[1]:-$0}")}}"

    local ts core_rem gql_rem rem ambient
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    rem="$(_chump_gh_rate_remaining)"
    core_rem="${rem% *}"
    gql_rem="${rem#* }"
    ambient="$(_chump_gh_ambient_path)"
    mkdir -p "$(dirname "$ambient")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"github_api_call","script":"%s","api":"%s","remaining_core":%s,"remaining_graphql":%s,"used_ms":%d,"rc":%d}\n' \
        "$ts" "$script_tag" "$api_tag" "$core_rem" "$gql_rem" "$used_ms" "$rc" \
        >> "$ambient" 2>/dev/null || true
}

_chump_gh_now_ms() {
    local ns
    ns="$(date +%s%N 2>/dev/null)"
    if [[ -z "$ns" || "$ns" == *N ]]; then
        # macOS date(1) lacks %N — fall back to python.
        python3 -c 'import time;print(int(time.time()*1000))'
        return
    fi
    printf '%d' "$(( ns / 1000000 ))"
}

chump_gh() {
    local api_tag started rc ended used_ms
    api_tag="$(chump_gh_api_tag "$@")"
    started="$(_chump_gh_now_ms)"
    set +e
    gh "$@"
    rc=$?
    set -e
    ended="$(_chump_gh_now_ms)"
    used_ms=$(( ended - started ))
    chump_gh_record "$api_tag" "$used_ms" "$rc" \
        "${CHUMP_GH_SCRIPT:-$(basename "${BASH_SOURCE[1]:-$0}")}"
    return "$rc"
}
