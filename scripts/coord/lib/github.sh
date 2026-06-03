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
        CHUMP_GH_SCRIPT="$(basename "$_chump_gh_caller")"
        export CHUMP_GH_SCRIPT
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
#
# INFRA-1968: when GitHub returns resets_at:unknown (or absent/0), the prior
# code wrote 0 to the flag file. Since 0 < now, the future-check always failed
# and every call re-emitted — observed as 6 emits in 60s on 2026-05-24.
# Fix: when resets_at is unknown/0, anchor the debounce window to
# (now + CHUMP_GH_EXHAUSTED_UNKNOWN_DEBOUNCE_S, default 60). State is shared
# across concurrent shim invocations via .chump-locks/graphql-exhausted-debounce-state.json.
_chump_gh_maybe_emit_exhausted() {
    # INFRA-2674: do NOT default $1 to 0 — empty/missing arg comes from a
    # malformed _chump_gh_rate_remaining parse (e.g. `gh api rate_limit` returned
    # an error JSON `{...}` that read drained into core_rem, leaving gql_rem
    # empty). Coercing empty → "0" caused the threshold check to spuriously
    # fire at 0 ≤ 100 → false graphql_exhausted cascade (31 events / 30 min
    # observed on 2026-06-03 with live GraphQL at 4266/5000). Require explicit
    # non-empty digit-only input before any comparison.
    [[ -n "${1:-}" && "${1}" =~ ^[0-9]+$ ]] || return 0
    local gql_rem="$1" resets_at="${2:-0}" ambient="${3:-}"
    local threshold="${CHUMP_GH_EXHAUSTED_THRESHOLD:-100}"
    local unknown_debounce_s="${CHUMP_GH_EXHAUSTED_UNKNOWN_DEBOUNCE_S:-60}"

    # Only fire when the value is under threshold.
    # AC1 (INFRA-2484): reject negative sentinels (-1) — handled by digit-only regex above.
    # AC1 (INFRA-2674): empty-string-as-zero coercion fixed in the guard above.
    [[ "$gql_rem" -le "$threshold" ]] || return 0

    local lock_dir
    lock_dir="$(dirname "$ambient")"
    local flag="$lock_dir/.graphql-exhausted-since"
    local now
    now="$(date +%s)"

    # INFRA-1968: if resets_at is 0 or "unknown", use a fixed debounce window
    # anchored to the last emit. Share state in the debounce-state JSON so
    # concurrent shim processes see the same last-emit timestamp.
    local resets_at_is_unknown=0
    if [[ "$resets_at" == "0" || "$resets_at" == "unknown" || -z "$resets_at" ]]; then
        resets_at_is_unknown=1
    fi

    # Debounce: if flag exists with a next-emit-allowed epoch in the future,
    # we're still in the same window — skip. If epoch is past or flag missing, emit.
    if [[ -f "$flag" ]]; then
        local prior_reset
        prior_reset="$(cat "$flag" 2>/dev/null | tr -d '\n')"
        if [[ "$prior_reset" =~ ^[0-9]+$ ]] && [[ "$prior_reset" -gt "$now" ]]; then
            return 0
        fi
    fi

    local ts resets_iso
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$resets_at_is_unknown" -eq 0 && "$resets_at" -gt 0 ]]; then
        resets_iso="$(date -u -r "$resets_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || python3 -c "import datetime,sys; print(datetime.datetime.utcfromtimestamp(int(sys.argv[1])).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$resets_at")"
    else
        resets_iso="unknown"
    fi

    local source_tag="${CHUMP_GH_SCRIPT:-chump_gh}"
    printf '{"ts":"%s","kind":"graphql_exhausted","threshold_seen":%s,"resets_at":"%s","source":"%s"}\n' \
        "$ts" "$gql_rem" "$resets_iso" "$source_tag" \
        >> "$ambient" 2>/dev/null || true

    # Write the next-emit-allowed epoch so subsequent calls in this window skip.
    # INFRA-1968: when resets_at is unknown/0, anchor to (now + debounce window)
    # so the flag is always a future timestamp and the debounce actually holds.
    local next_allowed
    if [[ "$resets_at_is_unknown" -eq 1 ]]; then
        next_allowed=$(( now + unknown_debounce_s ))
    else
        next_allowed="$resets_at"
    fi
    printf '%s' "$next_allowed" >"$flag" 2>/dev/null || true
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

    # AC2 (INFRA-2484): a failed gh call (rc != 0) cannot report truthful rate
    # data — the rate_limit sub-call may also have failed, yielding sentinel -1
    # values. Skip exhausted-emit to prevent false graphql_exhausted alarms.
    if [[ "$rc" != "0" ]]; then
        # AC3 (INFRA-2484): emit a debug breadcrumb so cascade triggers are auditable.
        printf '{"ts":"%s","kind":"gh_recording_skipped_rc_nonzero","script":"%s","api":"%s","rc":%d,"used_ms":%d}\n' \
            "$ts" "$script_tag" "$api_tag" "$rc" "$used_ms" \
            >> "$ambient" 2>/dev/null || true
        return 0
    fi

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

# ── INFRA-1079: per-script secondary rate-limit self-throttle ────────────────
# GitHub's SECONDARY rate-limit fires on rapid-fire density (calls/sec) in
# short windows, independent of the primary bucket. Observed today: 6× hits
# of "rate limit already exceeded" with primary GraphQL at 4000+/5000.
#
# Strategy: token-bucket window across the fleet via a shared lock file.
# INFRA-1112: split into two buckets — mutations (writes) get a tighter cap.
#   Mutations: .gh-throttle-window.mutation  CHUMP_GH_MUTATION_MAX (def 15/min)
#   Queries:   .gh-throttle-window.query     CHUMP_GH_QUERY_MAX    (def 60/min)
# Per-script override: CHUMP_GH_THROTTLE_<SCRIPT> still applies after class cap.
#
# Algorithm:
#   1. Classify call as mutation or query
#   2. Acquire flock on .gh-throttle.lock
#   3. Read class-specific window file; drop entries older than 60s
#   4. If len(window) >= limit: sleep 1s, release lock, retry (max 30s total)
#   5. Otherwise: append `now` to window, release, proceed
#
# Fail-safe: after 30s waited, let the call through (don't deadlock the fleet
# on a runaway throttle counter). Emit kind=gh_self_throttled at every delay.

# INFRA-1112: classify a gh invocation as "mutation" or "query".
# Mutations are writes that GitHub secondary-limits far more aggressively.
_chump_gh_classify_call() {
    local subcmd="${1:-}" flag2="${2:-}"
    case "$subcmd" in
        pr)
            case "$flag2" in
                merge|create|review|comment|edit|close|reopen) echo mutation; return ;;
            esac
            ;;
        issue)
            case "$flag2" in
                create|close|reopen|edit|comment|pin|unpin) echo mutation; return ;;
            esac
            ;;
        release)
            case "$flag2" in
                create|delete|edit|upload) echo mutation; return ;;
            esac
            ;;
        api)
            # Scan argv for -X/--method followed by POST/PATCH/PUT/DELETE
            local _saw_method=0 _upper
            for _a in "$@"; do
                if [[ "$_saw_method" -eq 1 ]]; then
                    _upper="$(echo "$_a" | tr '[:lower:]' '[:upper:]')"
                    case "$_upper" in POST|PATCH|PUT|DELETE) echo mutation; return ;; esac
                    _saw_method=0
                fi
                [[ "$_a" == "-X" || "$_a" == "--method" ]] && _saw_method=1
            done
            # --method=POST form
            for _a in "$@"; do
                _upper="$(echo "$_a" | tr '[:lower:]' '[:upper:]')"
                [[ "$_upper" =~ ^--METHOD=(POST|PATCH|PUT|DELETE)$ ]] && { echo mutation; return; }
            done
            ;;
    esac
    echo query
}

_chump_gh_throttle_wait() {
    local script_tag="${1:-?}"
    local api_class="${2:-query}"  # INFRA-1112: "mutation" or "query"

    # INFRA-1112: class-specific cap and window file
    local limit
    if [[ "$api_class" == "mutation" ]]; then
        limit="${CHUMP_GH_MUTATION_MAX:-15}"
    else
        limit="${CHUMP_GH_QUERY_MAX:-${CHUMP_GH_MAX_CALLS_PER_MIN:-60}}"
    fi
    # Per-script override still applies (takes precedence over class default)
    local override_var
    override_var="CHUMP_GH_THROTTLE_$(echo "$script_tag" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
    override_var="${override_var%_}"
    local override="${!override_var:-}"
    if [[ -n "$override" && "$override" =~ ^[0-9]+$ ]]; then
        limit="$override"
    fi

    [[ "$limit" -le 0 ]] && return 0   # disabled
    [[ "${CHUMP_GH_NO_THROTTLE:-0}" == "1" ]] && return 0

    local lock_dir
    lock_dir="$(dirname "$(_chump_gh_ambient_path)")"
    local lock_file="$lock_dir/.gh-throttle.lock"
    local window_file="$lock_dir/.gh-throttle-window.${api_class}"
    mkdir -p "$lock_dir" 2>/dev/null || true

    local started_wait
    started_wait="$(date +%s)"
    local total_wait_ms=0

    while true; do
        # Try to acquire the lock with a short timeout. flock is not strictly
        # required; we use it for safety. If unavailable (e.g. no flock(1) on
        # macOS by default), fall through without it — worst case: small
        # over-counting due to race, harmless.
        (
            if command -v flock >/dev/null 2>&1; then
                flock -w 2 200 || exit 1
            fi
            python3 - "$window_file" "$limit" "$total_wait_ms" "$script_tag" <<'PY' || exit $?
import json, os, sys, time

wf, limit, waited_ms_so_far, script = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
now = time.time()
window_secs = 60

# Read existing window
entries = []
if os.path.exists(wf):
    try:
        with open(wf) as f:
            data = json.load(f)
        if isinstance(data, list):
            entries = [e for e in data if isinstance(e, (int, float)) and (now - e) < window_secs]
    except Exception:
        entries = []

if len(entries) < limit:
    entries.append(now)
    try:
        with open(wf, "w") as f:
            json.dump(entries[-(limit + 10):], f)
    except Exception:
        pass
    sys.exit(0)  # OK — proceed

# At limit. Caller should sleep + retry.
sys.exit(7)
PY
        ) 200>"$lock_file"
        rc=$?
        if [[ "$rc" -eq 0 ]]; then
            return 0
        fi

        # Bucket full — sleep 1s and retry.
        local now_epoch; now_epoch="$(date +%s)"
        if [[ $(( now_epoch - started_wait )) -ge 30 ]]; then
            # Fail-safe: let the call through after 30s.
            local ambient; ambient="$(_chump_gh_ambient_path)"
            printf '{"ts":"%s","kind":"gh_self_throttled","script":"%s","api_class":"%s","waited_ms":30000,"calls_in_window":-1,"fail_safe":true}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$script_tag" "$api_class" \
                >> "$ambient" 2>/dev/null || true
            return 0
        fi
        sleep 1
        total_wait_ms=$(( total_wait_ms + 1000 ))
        # Emit one event per delay (debounce-light — operator wants to see this).
        local ambient; ambient="$(_chump_gh_ambient_path)"
        printf '{"ts":"%s","kind":"gh_self_throttled","script":"%s","api_class":"%s","waited_ms":%d,"calls_in_window":%d}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$script_tag" "$api_class" "$total_wait_ms" "$limit" \
            >> "$ambient" 2>/dev/null || true
    done
}

# ── INFRA-1080: pre-emptive backoff when GraphQL bucket runs low ─────────────
# INFRA-1040 already broadcasts kind=graphql_exhausted when remaining hits 0,
# but by then the next call already failed. This helper delays *background*
# calls when remaining is < CHUMP_GH_BACKOFF_THRESHOLD percent of the limit,
# so we never hit 0 in the first place.
#
# Classification (per-call):
#   CHUMP_GH_CALL_CRITICALITY=critical (default) — always proceed, never delayed
#   CHUMP_GH_CALL_CRITICALITY=background       — delayed when graphql tight
#
# Algorithm:
#   1. read remaining_graphql from rate_limit (free endpoint)
#   2. if background AND remaining < threshold percent:
#        sleep min(60, time_to_reset); re-check; max 1 retry
#   3. critical OR sufficient remaining: proceed
#
# Each delay emits kind=gh_preempted with {script, api, waited_s,
# remaining_percent_before, remaining_percent_after}.
_chump_gh_preempt_if_low() {
    local script_tag="${1:-?}"
    local api_tag="${2:-?}"
    local criticality="${CHUMP_GH_CALL_CRITICALITY:-critical}"
    # Critical calls are never preempted.
    [[ "$criticality" == "critical" ]] && return 0
    [[ "${CHUMP_GH_NO_PREEMPT:-0}" == "1" ]] && return 0

    local threshold_pct="${CHUMP_GH_BACKOFF_THRESHOLD:-10}"
    # Read remaining + reset
    local rem; rem="$(_chump_gh_rate_remaining)"
    local core_rem gql_rem resets_at
    read -r core_rem gql_rem resets_at <<<"$rem"
    : "${resets_at:=0}"

    # If we can't determine remaining, don't preempt (fail-open).
    [[ "$gql_rem" =~ ^-?[0-9]+$ ]] || return 0
    [[ "$gql_rem" -lt 0 ]] && return 0

    # 5000 is GitHub's GraphQL limit per token; matches rate_limit.graphql.limit.
    local limit=5000
    local pct=$(( gql_rem * 100 / limit ))
    [[ "$pct" -ge "$threshold_pct" ]] && return 0   # sufficient remaining, proceed

    # Below threshold + background → sleep
    local pct_before="$pct"
    local now sleep_for
    now="$(date +%s)"
    if [[ "$resets_at" -gt "$now" ]]; then
        sleep_for=$(( resets_at - now ))
    else
        sleep_for=60
    fi
    [[ "$sleep_for" -gt 60 ]] && sleep_for=60   # cap single sleep at 60s

    sleep "$sleep_for"

    # Re-check after sleep
    rem="$(_chump_gh_rate_remaining)"
    read -r core_rem gql_rem resets_at <<<"$rem"
    : "${gql_rem:=-1}"
    local pct_after=0
    if [[ "$gql_rem" =~ ^[0-9]+$ ]]; then
        pct_after=$(( gql_rem * 100 / limit ))
    fi

    local ambient; ambient="$(_chump_gh_ambient_path)"
    mkdir -p "$(dirname "$ambient")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"gh_preempted","script":"%s","api":"%s","waited_s":%d,"remaining_percent_before":%d,"remaining_percent_after":%d}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$script_tag" "$api_tag" "$sleep_for" "$pct_before" "$pct_after" \
        >> "$ambient" 2>/dev/null || true
}

# INFRA-1111: detect GitHub secondary rate-limit message in captured stderr.
_chump_gh_is_secondary_limit() {
    echo "${1:-}" | grep -qE 'rate limit already exceeded|You have exceeded a secondary rate limit'
}

chump_gh() {
    local api_tag started rc ended used_ms script_tag api_class
    api_tag="$(chump_gh_api_tag "$@")"
    script_tag="${CHUMP_GH_SCRIPT:-$(basename "${BASH_SOURCE[1]:-$0}")}"
    # INFRA-1112: classify before throttle so mutations get the tighter cap.
    api_class="$(_chump_gh_classify_call "$@")"
    # INFRA-1079: pre-call throttle to avoid secondary rate-limit.
    _chump_gh_throttle_wait "$script_tag" "$api_class"
    # INFRA-1080: pre-emptive backoff when graphql bucket is low (background only).
    _chump_gh_preempt_if_low "$script_tag" "$api_tag"
    started="$(_chump_gh_now_ms)"

    # INFRA-1111: exponential backoff on secondary rate-limit.
    # Bypass with CHUMP_GH_NO_RETRY=1.
    local _tmp_stderr=""
    if [[ "${CHUMP_GH_NO_RETRY:-0}" != "1" ]]; then
        _tmp_stderr="$(mktemp)"
    fi
    local _sleep_s=1 _retries=0 _total_waited_ms=0

    rc=0
    while true; do
        set +e
        if [[ -n "$_tmp_stderr" ]]; then
            # INFRA-1103: CHUMP_GH_SHIM_RECORDING=1 signals to the PATH shim that
            # this call is already throttled (_chump_gh_throttle_wait ran above).
            CHUMP_GH_SHIM_RECORDING=1 gh "$@" 2>"$_tmp_stderr"
            rc=$?
            cat "$_tmp_stderr" >&2 2>/dev/null || true
        else
            CHUMP_GH_SHIM_RECORDING=1 gh "$@"
            rc=$?
        fi
        set -e

        if [[ -n "$_tmp_stderr" ]] && (( rc != 0 )); then
            local _err
            _err="$(cat "$_tmp_stderr" 2>/dev/null || true)"
            if _chump_gh_is_secondary_limit "$_err" && (( _retries < 4 )); then
                sleep "$_sleep_s"
                _total_waited_ms=$(( _total_waited_ms + _sleep_s * 1000 ))
                _sleep_s=$(( _sleep_s * 2 <= 30 ? _sleep_s * 2 : 30 ))
                _retries=$(( _retries + 1 ))
                continue
            elif _chump_gh_is_secondary_limit "$_err" && (( _retries >= 4 )); then
                local ambient ts
                ambient="$(_chump_gh_ambient_path)"
                ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                printf '{"ts":"%s","kind":"gh_secondary_limit_hit","script":"%s","api":"%s","retries":%d,"total_waited_ms":%d}\n' \
                    "$ts" "$script_tag" "$api_tag" "$_retries" "$_total_waited_ms" \
                    >> "$ambient" 2>/dev/null || true
            fi
        fi
        break
    done
    [[ -n "$_tmp_stderr" ]] && rm -f "$_tmp_stderr" 2>/dev/null || true

    ended="$(_chump_gh_now_ms)"
    used_ms=$(( ended - started ))
    chump_gh_record "$api_tag" "$used_ms" "$rc" "$script_tag"
    return "$rc"
}
