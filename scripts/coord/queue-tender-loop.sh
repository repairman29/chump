#!/usr/bin/env bash
# scripts/coord/queue-tender-loop.sh — Chump curator-opus-queue-tender role CLI (META-243)
#
# Productizes the queue-tender curator: the periodic loop that keeps the PR
# merge queue moving by bringing BEHIND open PRs up to date with the base
# branch. Harness-neutral: launchd, Claude Code, opencode or a human all call
# it the same way.
#
# Lane discipline (see docs/process/QUEUE_TENDER_DOCTRINE.md): the tender only
# updates branches of open PRs. It never merges, never bypasses branch
# protection, never closes a PR. Merging stays with the merge train.
#
# Usage:
#   scripts/coord/queue-tender-loop.sh <subcommand>
#
# Subcommands:
#   tick        One tend cycle: list open PRs, update-branch the BEHIND ones
#               (subject to hysteresis + per-tick cap), emit kind=queue_tend_tick.
#               Exit 0 on a completed cycle (even if nothing needed tending).
#   heartbeat   Emit kind=queue_tend_heartbeat. Exit 0 always.
#   help        Print this.
#
# Exit codes: 0 ok, 2 bad subcommand.
#
# Env:
#   CHUMP_SKIP_QUEUE_TENDER=1         exit 0 immediately (panic-stop)
#   CHUMP_QUEUE_TENDER_DRY_RUN        1 (default) = log intent only; 0 = act
#   CHUMP_QUEUE_TENDER_HYSTERESIS_S   min seconds between updates of one PR (default 300)
#   CHUMP_QUEUE_TENDER_MAX_PER_TICK   max PR updates per tick (default 5)
#   CHUMP_QUEUE_TENDER_STATE_DIR      per-PR hysteresis state dir
#   CHUMP_QUEUE_TENDER_PR_FIXTURE     test hook: file of "<number>\t<mergeStateStatus>" lines
#   CHUMP_AMBIENT_LOG                 ambient.jsonl path override
#   CHUMP_SESSION_ID                  session id for emits (default: queue-tender-<pid>)

set -euo pipefail

if [[ "${CHUMP_SKIP_QUEUE_TENDER:-0}" == "1" ]]; then
    echo "[queue-tender] CHUMP_SKIP_QUEUE_TENDER=1 — skipping."
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# INFRA-1081/INFRA-1274: route gh reads through the throttled cache-first
# wrapper rather than calling the gh CLI raw in a hot-path script. Falls back
# to a bare passthrough if the lib can't be sourced.
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/coord/lib/github.sh" 2>/dev/null || true
command -v chump_gh >/dev/null 2>&1 || chump_gh() { gh "$@"; }

_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
SESSION_ID="${CHUMP_SESSION_ID:-queue-tender-$$}"
DRY_RUN="${CHUMP_QUEUE_TENDER_DRY_RUN:-1}"
HYSTERESIS_S="${CHUMP_QUEUE_TENDER_HYSTERESIS_S:-300}"
MAX_PER_TICK="${CHUMP_QUEUE_TENDER_MAX_PER_TICK:-5}"
STATE_DIR="${CHUMP_QUEUE_TENDER_STATE_DIR:-$LOCK_DIR/queue-tender}"

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_emit_kind() {
    local kind="$1" extra="${2:-}"
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    if [[ -n "$extra" ]]; then
        printf '{"ts":"%s","kind":"%s","session":"%s",%s}\n' \
            "$(_now_iso)" "$kind" "$SESSION_ID" "$extra" >> "$AMBIENT" 2>/dev/null || true
    else
        printf '{"ts":"%s","kind":"%s","session":"%s"}\n' \
            "$(_now_iso)" "$kind" "$SESSION_ID" >> "$AMBIENT" 2>/dev/null || true
    fi
}

# Print "<number>\t<mergeStateStatus>" for each open PR.
_list_open_prs() {
    if [[ -n "${CHUMP_QUEUE_TENDER_PR_FIXTURE:-}" ]]; then
        cat "$CHUMP_QUEUE_TENDER_PR_FIXTURE" 2>/dev/null || true
        return 0
    fi
    chump_gh pr list --state open --limit 100 --json number,mergeStateStatus \
        --jq '.[] | "\(.number)\t\(.mergeStateStatus)"' 2>/dev/null || true
}

# Hysteresis: 0 (true) if PR <n> was updated less than HYSTERESIS_S ago.
_recently_tended() {
    local n="$1" f="$STATE_DIR/pr-$1.ts" last now
    [[ -f "$f" ]] || return 1
    last="$(cat "$f" 2>/dev/null || echo 0)"
    [[ "$last" =~ ^[0-9]+$ ]] || return 1
    now="$(date +%s)"
    (( now - last < HYSTERESIS_S ))
}

_mark_tended() {
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    date +%s > "$STATE_DIR/pr-$1.ts" 2>/dev/null || true
}

_cmd_tick() {
    local seen=0 behind=0 updated=0 held=0 failed=0 n state
    echo "=== queue-tender tick @ $(_now_iso) (dry_run=$DRY_RUN) ==="
    while IFS=$'\t' read -r n state; do
        [[ -n "$n" ]] || continue
        seen=$((seen + 1))
        [[ "$state" == "BEHIND" ]] || continue
        behind=$((behind + 1))
        if _recently_tended "$n"; then
            held=$((held + 1))
            echo "  hold: #$n (updated < ${HYSTERESIS_S}s ago)"
            continue
        fi
        if (( updated >= MAX_PER_TICK )); then
            held=$((held + 1))
            echo "  cap:  #$n (per-tick cap $MAX_PER_TICK reached)"
            continue
        fi
        if [[ "$DRY_RUN" == "1" ]]; then
            echo "  [dry-run] would update-branch #$n"
            updated=$((updated + 1))
            continue
        fi
        # Plain update-branch only: no merge, no bypass (lane discipline).
        if gh pr update-branch "$n" >/dev/null 2>&1; then
            echo "  updated: #$n"
            _mark_tended "$n"
            updated=$((updated + 1))
        else
            echo "  failed: #$n (update-branch)"
            failed=$((failed + 1))
        fi
    done < <(_list_open_prs)
    # queue_tend_tick: emitted once per tick cycle (scanner anchor).
    _emit_kind queue_tend_tick "\"prs_seen\":$seen,\"behind\":$behind,\"updated\":$updated,\"held\":$held,\"failed\":$failed,\"dry_run\":$DRY_RUN"
    echo "[queue-tender] tick: seen=$seen behind=$behind updated=$updated held=$held failed=$failed"
    return 0
}

_cmd_heartbeat() {
    # queue_tend_heartbeat (scanner anchor).
    _emit_kind queue_tend_heartbeat
    echo "[queue-tender] heartbeat emitted"
}

_cmd_help() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

case "${1:-help}" in
    tick)       _cmd_tick ;;
    heartbeat)  _cmd_heartbeat ;;
    help|-h|--help) _cmd_help ;;
    *) echo "queue-tender-loop: unknown subcommand '${1}'" >&2; _cmd_help >&2; exit 2 ;;
esac
