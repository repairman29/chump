#!/usr/bin/env bash
# scripts/lib/reaper.sh — INFRA-1572
#
# Generic age + predicate + action engine for the subset of scripts/ops/*
# reapers whose logic reduces to: find candidates, decide whether each is
# old/stale enough, act on the ones that are. NOT every reaper fits this
# shape — most don't (see docs/audits/reaper-curation-2026-05.md for the
# per-reaper verdict). Only reach for this engine when your reaper's
# predicate really is "age >= threshold" (or a one-line custom predicate)
# and its action is a single command per candidate.
#
# Contract (all via env vars, set by the caller before sourcing):
#
#   REAPER_NAME            short id, used in log lines + default ambient kind
#                           (emits "${REAPER_NAME}_reaped")
#   REAPER_FIND_CMD         shell command (eval'd) that prints one candidate
#                           per line as: "<id>\t<age_seconds>\t<extra>"
#                           <extra> is free-form and passed through verbatim
#                           to the predicate/action commands (may be empty).
#   REAPER_AGE_THRESHOLD_S  integer seconds; default predicate reaps any
#                           candidate whose age_seconds >= this value.
#   REAPER_PREDICATE_CMD    optional. If set, eval'd per-candidate as
#                           `$REAPER_PREDICATE_CMD "$id" "$age" "$extra"`;
#                           exit 0 means "reap it". Overrides the default
#                           age-threshold predicate entirely.
#   REAPER_ACTION_CMD       eval'd per-candidate (only when not dry-run) as
#                           `$REAPER_ACTION_CMD "$id" "$age" "$extra"`.
#
# Usage from a reaper script:
#
#   source "$(dirname "$0")/../lib/reaper.sh"
#   REAPER_NAME=stale-bot-merge
#   REAPER_FIND_CMD='ps -eo pid=,etime=,args= | grep "bot-merge\.sh" | grep -v grep'
#   REAPER_AGE_THRESHOLD_S=3600
#   REAPER_ACTION_CMD='reaper_engine_kill'
#   reaper_engine_run "$@"
#
# DRY_RUN convention matches every other scripts/ops/* reaper: default
# dry-run, --execute flips it, --dry-run is accepted explicitly too.

set -uo pipefail

reaper_engine_kill() {
    local pid="$1"
    kill -TERM "$pid" 2>/dev/null || true
    sleep 2
    kill -KILL "$pid" 2>/dev/null || true
}

reaper_engine_run() {
    local dry_run=true
    for arg in "$@"; do
        case "$arg" in
            --execute) dry_run=false ;;
            --dry-run) dry_run=true ;;
        esac
    done

    : "${REAPER_NAME:?REAPER_NAME must be set}"
    : "${REAPER_FIND_CMD:?REAPER_FIND_CMD must be set}"
    local threshold="${REAPER_AGE_THRESHOLD_S:-0}"

    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)")"
    local lock_dir="${CHUMP_LOCK_DIR:-$repo_root/.chump-locks}"

    local reaped=0 skipped=0
    local id age extra

    while IFS=$'\t' read -r id age extra; do
        [[ -z "$id" ]] && continue
        age="${age:-0}"

        local should_reap=1
        if [[ -n "${REAPER_PREDICATE_CMD:-}" ]]; then
            if eval "$REAPER_PREDICATE_CMD" '"$id"' '"$age"' '"$extra"'; then
                should_reap=0
            else
                should_reap=1
            fi
        else
            if (( age >= threshold )); then
                should_reap=0
            else
                should_reap=1
            fi
        fi

        if [[ "$should_reap" -ne 0 ]]; then
            skipped=$((skipped + 1))
            continue
        fi

        if [[ "$dry_run" == "true" ]]; then
            echo "  WOULD REAP id=$id age=${age}s extra=$extra"
        else
            echo "  REAPING id=$id age=${age}s extra=$extra"
            eval "$REAPER_ACTION_CMD" '"$id"' '"$age"' '"$extra"'
            printf '{"ts":"%s","kind":"%s_reaped","id":"%s","age_s":%d}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REAPER_NAME" "$id" "$age" \
                >> "$lock_dir/ambient.jsonl" 2>/dev/null || true
        fi
        reaped=$((reaped + 1))
    done < <(eval "$REAPER_FIND_CMD")

    echo
    echo "${REAPER_NAME}-reaper: reaped=${reaped} skipped=${skipped} dry_run=${dry_run}"
}
