#!/usr/bin/env bash
# stall-threshold.sh — RESILIENT-1739
#
# Pure, unit-testable stall-detector threshold scaling + kill classification,
# extracted from scripts/dispatch/worker.sh so both can be exercised by a real
# behavioural test (scripts/ci/test-stall-threshold.sh).
#
# THE BUG THIS GUARDS (RESILIENT-1739): the stall-detector's flat 120s
# no-output threshold killed a thinking sonnet / a loaded-node cargo build
# mid-gap (observed: 867s of real tool activity, rc=143 at 120s of silence),
# and the resulting SIGTERM (rc=143) was then fed into classify_sub_failure()
# which can misread it as an account-level outage (credit-exhausted/rate-limit)
# — demoting the worker's backend for a kill the worker itself caused.
#
# Usage:
#   compute_stall_threshold EFFORT LOADAVG CORES [NODE_ENV_FILE]
#     -> echoes the effective stall threshold in seconds.
#     Defaults by effort: xs=300  s/m=600  l/xl=900 (unknown -> 600)
#     Load scaling: x1.5 when LOADAVG > CORES*0.7 (applied to the computed
#       default only — an explicit override below is used as-is).
#     Override: CHUMP_STALL_THRESHOLD_S read fresh from NODE_ENV_FILE (default
#       ~/.chump/node.env) on every call — NOT just the inherited process env
#       — so a node.env edit takes effect on the worker's very next cycle
#       without a `systemctl restart chump-worker@N` (AC3). Process env
#       CHUMP_STALL_THRESHOLD_S (e.g. set directly by a test harness) is
#       honored when no node.env override is present.
#
#   stall_kill_classify MARKER_PRESENT(0|1)
#     -> echoes "stall_kill" when MARKER_PRESENT=1, else "none".
#     Mirrors classify_sub_failure()'s vocabulary (credit-exhausted |
#     rate-limit | auth-invalid | none) with a distinct class so a
#     self-inflicted stall kill is never mistaken for a sub-backend outage.

compute_stall_threshold() {
    local effort="${1:-s}" loadavg="${2:-0}" cores="${3:-4}"
    local node_env_file="${4:-${CHUMP_NODE_ENV_FILE:-${HOME:-/tmp}/.chump/node.env}}"
    local override=""

    if [[ -r "$node_env_file" ]]; then
        override="$(grep -E '^[[:space:]]*(export[[:space:]]+)?CHUMP_STALL_THRESHOLD_S=' "$node_env_file" 2>/dev/null \
            | tail -1 \
            | sed -E 's/^[[:space:]]*(export[[:space:]]+)?CHUMP_STALL_THRESHOLD_S=//; s/^["'\'']//; s/["'\'']$//' \
            | tr -d '[:space:]' || true)"
    fi
    if [[ -z "$override" && -n "${CHUMP_STALL_THRESHOLD_S:-}" ]]; then
        override="$CHUMP_STALL_THRESHOLD_S"
    fi
    if [[ -n "$override" ]]; then
        printf '%s' "$override"
        return 0
    fi

    local base
    case "$effort" in
        xs)    base=300 ;;
        s|m)   base=600 ;;
        l|xl)  base=900 ;;
        *)     base=600 ;;
    esac

    # Load scaling: x1.5 when loadavg > cores*0.7. awk does the float compare;
    # a non-numeric/missing loadavg or cores falls through to "not scaled".
    if awk -v la="$loadavg" -v c="$cores" 'BEGIN{exit !(la+0 > (c+0)*0.7)}' 2>/dev/null; then
        base=$(( base * 3 / 2 ))
    fi

    printf '%s' "$base"
}

stall_kill_classify() {
    local marker_present="${1:-0}"
    if [[ "$marker_present" == "1" ]]; then
        echo "stall_kill"
    else
        echo "none"
    fi
}
