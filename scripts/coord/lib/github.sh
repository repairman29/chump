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

# INFRA-999: capture the sourcing-script's basename so the shim can tag
# every `gh ...` call with the right `script` field, even when bash is
# the immediate parent of the shim subprocess (ppid walks hit the shell
# wrapper, not the script). Caller can override by setting CHUMP_GH_SCRIPT
# explicitly before sourcing.
if [[ -z "${CHUMP_GH_SCRIPT:-}" ]]; then
    # Last element of BASH_SOURCE is the outermost script. Negative
    # indexing not universally supported (bash < 4.3); compute the index.
    _chump_gh_last_idx=$(( ${#BASH_SOURCE[@]} - 1 ))
    if (( _chump_gh_last_idx >= 0 )); then
        _chump_gh_caller="${BASH_SOURCE[$_chump_gh_last_idx]:-$0}"
    else
        _chump_gh_caller="$0"
    fi
    if [[ -n "$_chump_gh_caller" && "$(basename "$_chump_gh_caller")" != "github.sh" ]]; then
        export CHUMP_GH_SCRIPT="$(basename "$_chump_gh_caller")"
    fi
    unset _chump_gh_caller _chump_gh_last_idx
fi

# INFRA-999 transparent telemetry: prepend the gh shim dir to PATH so every
# `gh ...` invocation in any script that sources this lib is auto-recorded
# without per-call wrapping. The shim resolves the real gh by skipping its
# own directory in PATH (no infinite recursion).
#
# Opt-out: export CHUMP_GH_NO_PATH_INJECT=1 before sourcing this file.
# Per-call opt-out: CHUMP_GH_NO_SHIM=1 gh ...
if [[ "${CHUMP_GH_NO_PATH_INJECT:-0}" != "1" ]]; then
    _chump_gh_shim_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/gh-shim" 2>/dev/null && pwd)"
    if [[ -n "$_chump_gh_shim_dir" && -x "$_chump_gh_shim_dir/gh" ]]; then
        case ":$PATH:" in
            *":$_chump_gh_shim_dir:"*) : ;;
            *) export PATH="$_chump_gh_shim_dir:$PATH" ;;
        esac
    fi
    unset _chump_gh_shim_dir
fi

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

# Read remaining core+graphql + graphql resets_at via `gh api rate_limit`.
# Returns "core graphql resets_at_epoch" — third field added in INFRA-1040
# so we can debounce graphql_exhausted emissions across calls in the same
# reset window. On failure returns "-1 -1 0".
# CHUMP_GH_NO_SHIM=1 bypasses the PATH shim — recursive-trap fix: the shim
# itself calls chump_gh_record which calls this function, and without the
# bypass we'd hit the shim again → infinite loop.
_chump_gh_rate_remaining() {
    local out
    out="$(CHUMP_GH_NO_SHIM=1 gh api rate_limit --jq '"\(.resources.core.remaining) \(.resources.graphql.remaining) \(.resources.graphql.reset)"' 2>/dev/null || true)"
    if [[ -z "$out" ]]; then
        printf '%s' "-1 -1 0"
        return
    fi
    printf '%s' "$out"
}

# INFRA-1040: emit kind=graphql_exhausted to ambient.jsonl when remaining_graphql
# crosses the low-water threshold. Debounced to once per reset window so the
# event fires on the first hit, not on every subsequent call. The flag file
# stores the next-reset epoch; subsequent calls within the window skip emission.
_chump_gh_maybe_emit_exhausted() {
    local gql_rem="${1:-0}" resets_at="${2:-0}" ambient="${3:-}"
    local threshold="${CHUMP_GH_EXHAUSTED_THRESHOLD:-100}"

    # Only fire when we have a real number under threshold.
    [[ "$gql_rem" =~ ^-?[0-9]+$ ]] || return 0
    [[ "$gql_rem" -le "$threshold" ]] || return 0

    local lock_dir
    lock_dir="$(dirname "$ambient")"
    local flag="$lock_dir/.graphql-exhausted-since"
    local now
    now="$(date +%s)"

    # Debounce: if flag exists with a resets_at in the future, we're still
    # in the same window — skip. If resets_at is past or flag missing, emit.
    if [[ -f "$flag" ]]; then
        local prior_reset
        prior_reset="$(cat "$flag" 2>/dev/null | tr -d '\n')"
        if [[ "$prior_reset" =~ ^[0-9]+$ ]] && [[ "$prior_reset" -gt "$now" ]]; then
            return 0
        fi
    fi

    local ts resets_iso
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$resets_at" -gt 0 ]]; then
        resets_iso="$(date -u -r "$resets_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || python3 -c "import datetime,sys; print(datetime.datetime.utcfromtimestamp(int(sys.argv[1])).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$resets_at")"
    else
        resets_iso="unknown"
    fi

    local source_tag="${CHUMP_GH_SCRIPT:-chump_gh}"
    printf '{"ts":"%s","kind":"graphql_exhausted","threshold_seen":%s,"resets_at":"%s","source":"%s"}\n' \
        "$ts" "$gql_rem" "$resets_iso" "$source_tag" \
        >> "$ambient" 2>/dev/null || true

    # Write the next-reset epoch so subsequent calls in this window skip.
    printf '%s' "$resets_at" >"$flag" 2>/dev/null || true
}

# chump_gh_record API_TAG USED_MS RC [SCRIPT_OVERRIDE]
chump_gh_record() {
    [[ "${CHUMP_GH_SILENT:-0}" == "1" ]] && return 0
    # INFRA-999: when the PATH shim is doing the recording for this call,
    # explicit chump_gh_record invocations from outer wrappers (e.g.
    # bot-merge.sh::gh_with_backoff) must skip to avoid double-counting.
    [[ "${CHUMP_GH_SHIM_RECORDING:-0}" == "1" ]] && return 0
    local api_tag="${1:-?}" used_ms="${2:-0}" rc="${3:-0}" script_tag
    script_tag="${4:-${CHUMP_GH_SCRIPT:-$(basename "${BASH_SOURCE[1]:-$0}")}}"

    local ts core_rem gql_rem resets_at rem ambient
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    rem="$(_chump_gh_rate_remaining)"
    # rem is "core graphql resets_at" (INFRA-1040 added third field).
    read -r core_rem gql_rem resets_at <<<"$rem"
    : "${resets_at:=0}"
    ambient="$(_chump_gh_ambient_path)"
    mkdir -p "$(dirname "$ambient")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"github_api_call","script":"%s","api":"%s","remaining_core":%s,"remaining_graphql":%s,"used_ms":%d,"rc":%d}\n' \
        "$ts" "$script_tag" "$api_tag" "$core_rem" "$gql_rem" "$used_ms" "$rc" \
        >> "$ambient" 2>/dev/null || true

    # INFRA-1040: fleet-wide signal when GraphQL bucket is exhausted.
    _chump_gh_maybe_emit_exhausted "$gql_rem" "$resets_at" "$ambient"
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
