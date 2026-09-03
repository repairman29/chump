# shellcheck shell=bash
# halt-class-emit.sh — CREDIBLE-108/CREDIBLE-109 slices: failure-class
# taxonomy + structured event emission for halt-class detectors.
#
# Provides four things:
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
#   3. halt_predicate_emit PREDICATE STATUS DURATION_MS [DETAIL_JSON]
#        Appends one of three distinct events —
#        halt_predicate_success | halt_predicate_failure |
#        halt_predicate_timeout — to .chump-locks/ambient.jsonl (CREDIBLE-622,
#        CREDIBLE-109 slice). ambient.jsonl is the fleet's configured
#        observability backend: fleet-brief/waste-tally/kpi-report consume it
#        directly, and it follows the same OTel-semconv field-naming
#        convention as src/genai_conv.rs (predicate name, timestamp, duration)
#        so any OTel-compatible collector can ingest it without a bespoke
#        parser. Distinct kinds (rather than one kind + a status field) let
#        consumers filter/aggregate per-outcome without parsing JSON first.
#
#   4. halt_predicate_run PREDICATE TIMEOUT_S -- CMD...
#        Runs CMD under `timeout TIMEOUT_S`, measures wall-clock duration,
#        and emits the matching halt_predicate_* event automatically.
#        Returns CMD's exit code unchanged.
#
# Source from any script:
#   source "$(dirname "$0")/../lib/halt-class-emit.sh"
#   halt_class_emit "auth-check" success "" '{"probe":"validity"}'
#   halt_class_emit "worker-spawn" failure "connection refused"
#   halt_class_emit "bot-merge" timeout "step=init exceeded 900s"
#   halt_predicate_run "auth-validity" 30 -- scripts/coord/auth-status.sh
#
# Bash 3.2+ compatible (macOS default). Uses python3 for JSON when
# available, falls back to a hand-rolled emitter otherwise.

# scanner-anchor: "kind":"halt_class_emit"
# scanner-anchor: "kind":"halt_predicate_success"
# scanner-anchor: "kind":"halt_predicate_failure"
# scanner-anchor: "kind":"halt_predicate_timeout"
# (kind is computed dynamically in halt_predicate_emit below, so the static
# event-registry scanner can't see the literal from the emit call alone —
# these anchors satisfy the emit-without-register check. CREDIBLE-622.)

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

# _halt_predicate_now_ms — best-effort millisecond clock.
# GNU date supports `%N` (nanoseconds); BSD/macOS date does not and echoes
# the literal "N" back, so detect that and fall back to second granularity
# rather than emitting a garbage duration.
_halt_predicate_now_ms() {
    local ns
    ns="$(date +%s%N 2>/dev/null)"
    if [[ "$ns" =~ ^[0-9]+$ ]] && [[ ${#ns} -gt 10 ]]; then
        echo $(( ns / 1000000 ))
    else
        echo $(( $(date +%s) * 1000 ))
    fi
}

# halt_predicate_emit PREDICATE STATUS DURATION_MS [DETAIL_JSON]
# PREDICATE   — name of the halt-class predicate that ran (e.g. "auth-validity").
# STATUS      — success | failure | timeout. Maps 1:1 to the emitted kind:
#               halt_predicate_success | halt_predicate_failure | halt_predicate_timeout.
# DURATION_MS — execution duration in milliseconds (integer).
# DETAIL_JSON — optional free-form JSON object merged in as "detail".
halt_predicate_emit() {
    local predicate="${1:?halt_predicate_emit needs a predicate name}"
    local status="${2:?halt_predicate_emit needs a status}"
    local duration_ms="${3:?halt_predicate_emit needs a duration_ms}"
    local detail="${4:-}"
    [[ -z "$detail" ]] && detail='{}'

    local kind
    case "$status" in
        success) kind="halt_predicate_success" ;;
        failure) kind="halt_predicate_failure" ;;
        timeout) kind="halt_predicate_timeout" ;;
        *)
            echo "halt_predicate_emit: invalid status '$status' (want success|failure|timeout)" >&2
            return 1
            ;;
    esac

    if ! [[ "$duration_ms" =~ ^[0-9]+$ ]]; then
        echo "halt_predicate_emit: duration_ms must be a non-negative integer, got '$duration_ms'" >&2
        return 1
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
detail_raw = sys.argv[5]
try:
    detail = json.loads(detail_raw)
except Exception:
    detail = {'raw': detail_raw}
print(json.dumps({
    'kind': sys.argv[1],
    'predicate': sys.argv[2],
    'ts': sys.argv[3],
    'duration_ms': int(sys.argv[4]),
    'detail': detail,
}))
" "$kind" "$predicate" "$ts" "$duration_ms" "$detail" 2>/dev/null || true)
    fi
    if [[ -z "$json" ]]; then
        local esc_predicate esc_detail
        esc_predicate="$(printf '%s' "$predicate" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        esc_detail="$detail"
        json="{\"kind\":\"$kind\",\"predicate\":\"$esc_predicate\",\"ts\":\"$ts\",\"duration_ms\":$duration_ms,\"detail\":$esc_detail}"
    fi
    printf '%s\n' "$json" >> "$ambient" 2>/dev/null || true
}

# halt_predicate_run PREDICATE TIMEOUT_S [--] CMD...
# Runs CMD (optionally under `timeout TIMEOUT_S` when the `timeout` binary
# is available), measures wall-clock duration, and emits the matching
# halt_predicate_* event via halt_predicate_emit. Returns CMD's exit code
# unchanged (124 on timeout, per `timeout`'s convention).
halt_predicate_run() {
    local predicate="${1:?halt_predicate_run needs a predicate name}"
    local timeout_s="${2:?halt_predicate_run needs a timeout in seconds}"
    shift 2
    [[ "${1:-}" == "--" ]] && shift

    local start_ms end_ms duration_ms rc
    start_ms="$(_halt_predicate_now_ms)"
    if command -v timeout >/dev/null 2>&1; then
        timeout "${timeout_s}" "$@"
        rc=$?
    else
        "$@"
        rc=$?
    fi
    end_ms="$(_halt_predicate_now_ms)"
    duration_ms=$(( end_ms - start_ms ))
    [[ "$duration_ms" -lt 0 ]] && duration_ms=0

    if [[ $rc -eq 124 ]]; then
        halt_predicate_emit "$predicate" timeout "$duration_ms" "{\"exit_code\":$rc}"
    elif [[ $rc -eq 0 ]]; then
        halt_predicate_emit "$predicate" success "$duration_ms" "{\"exit_code\":$rc}"
    else
        halt_predicate_emit "$predicate" failure "$duration_ms" "{\"exit_code\":$rc}"
    fi
    return $rc
}
