#!/usr/bin/env bash
# curator-no-idle-watchdog.sh — INFRA-2210 AC4
#
# Operator directive: "no idle curators, ship aggressively for 12h, conserve
# OFF." The curator-loop.sh scripts (ci-audit / handoff / infra-watcher /
# decompose / md-links / external-collab / target / shepherd) now try a
# fallback action before declaring a tick quiet, and emit
# kind=curator_no_op_avoided each time they do. This watchdog grades whether
# that discipline is actually holding: over the last hour, what fraction of
# curator heartbeats/ticks were accompanied by a no-op-avoided action?
#
# A ratio below 0.5 means more than half the fleet's curator cycles are
# still idling — "curator went lazy" — and gets an ALERT emitted to
# ambient.jsonl so it surfaces in the standard pre-flight tail.
#
# Usage:
#   scripts/ops/curator-no-idle-watchdog.sh [--window-secs N] [--threshold R] [--quiet]
#
# Exit codes: 0 always (fail-open observability tool; ALERT is the signal,
# not a nonzero exit — matches the reaper-heartbeat-watchdog pattern).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"

WINDOW_SECS=3600
THRESHOLD="0.5"
QUIET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --window-secs) WINDOW_SECS="$2"; shift 2 ;;
        --threshold)   THRESHOLD="$2"; shift 2 ;;
        --quiet)       QUIET=1; shift ;;
        -h|--help)
            sed -n '2,24p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [[ ! -f "$AMBIENT" ]]; then
    echo "[curator-no-idle-watchdog] no ambient log at $AMBIENT — nothing to grade" >&2
    exit 0
fi

now_epoch="$(date -u +%s)"
cutoff_epoch=$(( now_epoch - WINDOW_SECS ))

HEARTBEAT_KINDS='ci_audit_heartbeat|handoff_heartbeat|md_links_heartbeat|curator_tick_outcome|infra_watcher_finding|external_collab_finding'

heartbeats=0
avoided=0
while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ts="$(printf '%s' "$line" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')"
    [[ -n "$ts" ]] || continue
    ev_epoch="$(date -u -d "$ts" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || echo 0)"
    (( ev_epoch >= cutoff_epoch )) || continue
    kind="$(printf '%s' "$line" | sed -n 's/.*"kind":"\([^"]*\)".*/\1/p')"
    case "$kind" in
        curator_no_op_avoided)
            avoided=$((avoided + 1))
            heartbeats=$((heartbeats + 1))
            ;;
        *_heartbeat|curator_tick_outcome)
            heartbeats=$((heartbeats + 1))
            ;;
    esac
done < <(tail -5000 "$AMBIENT" 2>/dev/null || true)

ratio="0"
if (( heartbeats > 0 )); then
    ratio="$(awk -v a="$avoided" -v h="$heartbeats" 'BEGIN{printf "%.3f", a/h}')"
fi

below_threshold=0
if [[ "$heartbeats" -gt 0 ]]; then
    below_threshold="$(awk -v r="$ratio" -v t="$THRESHOLD" 'BEGIN{print (r < t) ? 1 : 0}')"
fi

if [[ $QUIET -eq 0 ]]; then
    printf '[curator-no-idle-watchdog] window=%ds heartbeats=%d no_op_avoided=%d ratio=%s threshold=%s\n' \
        "$WINDOW_SECS" "$heartbeats" "$avoided" "$ratio" "$THRESHOLD"
fi

if [[ "$below_threshold" == "1" ]]; then
    msg="curator no-op-avoided ratio ${ratio} < threshold ${THRESHOLD} over ${WINDOW_SECS}s (${avoided}/${heartbeats}) — curators are idling instead of taking fallback action per INFRA-2210"
    printf 'ALERT [curator_lazy] %s\n' "$msg" >&2
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"event":"ALERT","kind":"curator_lazy","ts":"%s","ratio":%s,"heartbeats":%d,"avoided":%d,"window_secs":%d,"reason":"%s"}\n' \
        "$ts" "$ratio" "$heartbeats" "$avoided" "$WINDOW_SECS" "$msg" \
        >> "$AMBIENT" 2>/dev/null || true
fi

exit 0
