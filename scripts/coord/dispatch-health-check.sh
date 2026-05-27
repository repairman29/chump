#!/usr/bin/env bash
# dispatch-health-check.sh — META-116
#
# Scans ps aux for hung git-commit / pre-commit child processes that may be
# blocking a dispatched Sonnet subagent (or any operator session). Emits
# ambient kind=dispatch_hung_hook_detected when a process matches.
#
# Usage:
#   bash scripts/coord/dispatch-health-check.sh           # report-only
#   bash scripts/coord/dispatch-health-check.sh --kill    # also kill PIDs >threshold
#
# Discipline: when a dispatched Agent appears "abandoned" (no completion
# notification, lease released, worktree state-fresh), run this BEFORE
# attempting shepherd-takeover. Hung hook is a common false-positive for
# "agent crashed" — killing the hook unblocks the agent's own commit + the
# agent completes normally without takeover.
#
# Real-world precedent (META-116):
#   2026-05-27 14:56Z — INFRA-2000 dispatch had pre-commit wedged 5+ min;
#   shepherd assumed Sonnet abandoned + tried takeover; both stuck on same
#   hook; killing the hook PIDs unblocked Sonnet's commit which completed
#   normally; shepherd takeover was duplicate work.
#
# Env tunables:
#   CHUMP_DISPATCH_HUNG_THRESHOLD_S  default 120 (2 min)
#   CHUMP_AMBIENT_LOG                override .chump-locks/ambient.jsonl path
#   CHUMP_AMBIENT_DISABLE=1          skip ambient emit (for tests)

set -euo pipefail

REPO_ROOT="${CHUMP_REPO:-${CHUMP_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
THRESHOLD_S="${CHUMP_DISPATCH_HUNG_THRESHOLD_S:-120}"
SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-dispatch-health-check-$$}}"

KILL_MODE=0
if [ "${1:-}" = "--kill" ]; then
    KILL_MODE=1
fi

found=0

# Find candidate processes matching git-commit + pre-commit, with their wall-clock age.
# Use process substitution (not pipe-into-while) so the loop runs in the parent shell
# scope (preserves $found mutation) and an empty match doesn't trigger pipefail under
# set -euo pipefail.
while read -r pid etime command; do
        # Parse etime: D-HH:MM:SS or HH:MM:SS or MM:SS
        secs=0
        case "$etime" in
            *-*)
                # Days-HH:MM:SS
                days=${etime%%-*}
                rest=${etime#*-}
                IFS=: read -r h m s <<<"$rest"
                secs=$((days*86400 + h*3600 + m*60 + s))
                ;;
            *:*:*)
                IFS=: read -r h m s <<<"$etime"
                secs=$((h*3600 + m*60 + s))
                ;;
            *:*)
                IFS=: read -r m s <<<"$etime"
                secs=$((m*60 + s))
                ;;
            *)
                secs=0
                ;;
        esac

        if [ "$secs" -ge "$THRESHOLD_S" ]; then
            found=1
            echo "[dispatch-health-check] HUNG: pid=$pid age=${secs}s cmd=$command"

            # Ambient emit (unless disabled)
            if [ "${CHUMP_AMBIENT_DISABLE:-0}" != "1" ]; then
                ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
                printf '{"ts":"%s","kind":"dispatch_hung_hook_detected","source":"dispatch-health-check","session":"%s","pid":%s,"age_s":%s,"cmd":"%s"}\n' \
                    "$ts" "$SESSION_ID" "$pid" "$secs" "$(echo "$command" | head -c 200 | sed 's/"/\\"/g')" \
                    >> "$AMBIENT_LOG" 2>/dev/null || true
            fi

            if [ "$KILL_MODE" = "1" ]; then
                if kill -9 "$pid" 2>/dev/null; then
                    echo "[dispatch-health-check] killed pid=$pid"
                else
                    echo "[dispatch-health-check] failed-to-kill pid=$pid (may have exited)" >&2
                fi
            fi
        fi
    done < <(ps -eo pid,etime,command 2>/dev/null \
                | grep -E ' (git commit| ?bash .*pre-commit| ?/bin/bash.*pre-commit)' \
                | grep -v 'grep' \
                || true)

if [ "$found" = "0" ]; then
    echo "[dispatch-health-check] no hung commit/pre-commit children detected (threshold=${THRESHOLD_S}s)"
    exit 0
fi

# Exit non-zero IF in report-only mode AND we found hung procs (signal to operator)
if [ "$KILL_MODE" = "0" ]; then
    echo "[dispatch-health-check] report-only mode; re-run with --kill to remediate (or kill manually)" >&2
    exit 1
fi
exit 0
