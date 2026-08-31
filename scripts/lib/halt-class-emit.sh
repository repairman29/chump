# shellcheck shell=bash
# halt-class-emit.sh — CREDIBLE-108 slice: failure-class taxonomy + structured
# event emission for halt-class detectors.
#
# Provides two things:
#   1. halt_class_categorize REASON
#        Classifies a free-text failure reason into "transient" or
#        "permanent" using a keyword taxonomy. Transient failures (rate
#        limits, network blips, lock contention) are worth retrying;
#        permanent failures (auth dead, missing credential, bad config)
#        are not — retrying just burns cycles.
#
#   2. halt_class_emit NAME STATUS REASON [DETAIL_JSON]
#        Appends one structured event to .chump-locks/ambient.jsonl.
#        STATUS is one of: success | failure | timeout.
#        For status=failure or status=timeout, REASON is run through
#        halt_class_categorize and the result is attached as
#        "failure_class". For status=success, failure_class is "none".
#
# Source from any script:
#   source "$(dirname "$0")/../lib/halt-class-emit.sh"
#   halt_class_emit "auth-check" success "" '{"probe":"validity"}'
#   halt_class_emit "worker-spawn" failure "connection refused"
#   halt_class_emit "bot-merge" timeout "step=init exceeded 900s"
#
# Bash 3.2+ compatible (macOS default). Uses python3 for JSON when
# available, falls back to a hand-rolled emitter otherwise.

# _halt_class_lock_dir — resolve .chump-locks from any worktree.
_halt_class_lock_dir() {
    local common
    common="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    if [[ "$common" == ".git" ]]; then
        echo "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.chump-locks"
    else
        local root
        root="$(cd "$common/.." && pwd)"
        echo "$root/.chump-locks"
    fi
}

# halt_class_categorize REASON
# Echoes "transient" or "permanent" based on keyword match against REASON
# (case-insensitive). Defaults to "transient" when nothing matches — an
# unrecognized failure is more often a blip than a structural break, and a
# transient default costs one wasted retry rather than a false halt.
halt_class_categorize() {
    local reason="${1:-}"
    local lower
    lower="$(printf '%s' "$reason" | tr '[:upper:]' '[:lower:]')"

    case "$lower" in
        *"rate limit"*|*"rate-limit"*|*"429"*|*"timeout"*|*"timed out"*| \
        *"connection reset"*|*"connection refused"*|*"econnreset"*| \
        *"temporarily unavailable"*|*"lock contention"*|*"lease held"*| \
        *"503"*|*"502"*|*"could not resolve host"*|*"network"*|*"retry"*)
            echo "transient"
            ;;
        *"auth"*"dead"*|*"authentication failed"*|*"401"*|*"403"*| \
        *"credential"*"missing"*|*"no valid auth"*|*"permission denied"*| \
        *"not found"*|*"404"*|*"invalid config"*|*"missing required"*| \
        *"compile error"*|*"syntax error"*|*"fatal"*)
            echo "permanent"
            ;;
        *)
            echo "transient"
            ;;
    esac
}

# halt_class_emit NAME STATUS [REASON] [DETAIL_JSON]
# NAME    — the detector/script emitting the event (e.g. "bot-merge").
# STATUS  — success | failure | timeout.
# REASON  — free-text reason (empty for success). Categorized via
#           halt_class_categorize into failure_class for failure/timeout.
# DETAIL_JSON — optional free-form JSON object merged in as "detail".
halt_class_emit() {
    local name="${1:?halt_class_emit needs a name}"
    local status="${2:?halt_class_emit needs a status}"
    local reason="${3:-}"
    local detail="${4:-}"
    [[ -z "$detail" ]] && detail='{}'

    case "$status" in
        success|failure|timeout) ;;
        *)
            echo "halt_class_emit: invalid status '$status' (want success|failure|timeout)" >&2
            return 1
            ;;
    esac

    local failure_class="none"
    if [[ "$status" == "failure" || "$status" == "timeout" ]]; then
        failure_class="$(halt_class_categorize "$reason")"
    fi

    local lock_dir ambient ts
    lock_dir="$(_halt_class_lock_dir)"
    ambient="$lock_dir/ambient.jsonl"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    mkdir -p "$lock_dir" 2>/dev/null || true

    local json
    if command -v python3 >/dev/null 2>&1; then
        json=$(python3 -c "
import json, sys
detail_raw = sys.argv[6]
try:
    detail = json.loads(detail_raw)
except Exception:
    detail = {'raw': detail_raw}
print(json.dumps({
    'event': 'halt_class_emit',
    'kind': 'halt_class_emit',
    'name': sys.argv[1],
    'status': sys.argv[2],
    'reason': sys.argv[3],
    'failure_class': sys.argv[4],
    'ts': sys.argv[5],
    'detail': detail,
}))
" "$name" "$status" "$reason" "$failure_class" "$ts" "$detail" 2>/dev/null || true)
    fi
    if [[ -z "$json" ]]; then
        local esc_reason esc_detail
        esc_reason="$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        esc_detail="$detail"
        json="{\"event\":\"halt_class_emit\",\"kind\":\"halt_class_emit\",\"name\":\"$name\",\"status\":\"$status\",\"reason\":\"$esc_reason\",\"failure_class\":\"$failure_class\",\"ts\":\"$ts\",\"detail\":$esc_detail}"
    fi
    printf '%s\n' "$json" >> "$ambient" 2>/dev/null || true
}
