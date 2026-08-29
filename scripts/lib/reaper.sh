#!/usr/bin/env bash
# scripts/lib/reaper.sh — INFRA-1572
#
# Generic age/predicate/action engine for the small subset of scripts/ops/
# reapers whose shape is "enumerate candidates, decide per-candidate whether
# to act, act, report, optionally emit one ambient event." Most reapers in
# scripts/ops/ do NOT fit this shape (they carry substantial domain-specific
# state machines — GitHub PR status, lease/heartbeat liveness, cargo cache
# layout) and are intentionally NOT ported to this engine. See
# docs/audits/reaper-curation-2026-05.md for the per-reaper verdict.
#
# Contract: the caller sets these variables, then calls `reaper_engine_run`.
#
#   REAPER_NAME           short name used in the summary line
#   REAPER_FIND_CMD       shell command (string, run via eval) that prints
#                         one candidate per line on stdout
#   REAPER_PREDICATE_CMD  shell command (string, run via eval) that inspects
#                         $candidate and exits 0 iff the candidate should be
#                         reaped
#   REAPER_ACTION_CMD     shell command (string, run via eval) that performs
#                         the reap on $candidate. Only invoked when
#                         REAPER_DRY_RUN=false.
#   REAPER_DRY_RUN        "true" (default) or "false"
#   REAPER_LOCK_DIR       optional, defaults to .chump-locks under repo root
#   REAPER_AMBIENT_KIND   optional; when set and reaped>0 and not dry-run,
#                         appends {"ts":...,"kind":<this>,"count":N} to
#                         $REAPER_LOCK_DIR/ambient.jsonl
#
# $candidate is in scope for REAPER_PREDICATE_CMD and REAPER_ACTION_CMD.
#
# Returns via stdout: "reaped=N skipped=N" is embedded in the summary line;
# also exports REAPER_ENGINE_REAPED / REAPER_ENGINE_SKIPPED for callers that
# want to branch on counts.

reaper_engine_run() {
    : "${REAPER_NAME:?REAPER_NAME must be set}"
    : "${REAPER_FIND_CMD:?REAPER_FIND_CMD must be set}"
    : "${REAPER_PREDICATE_CMD:?REAPER_PREDICATE_CMD must be set}"
    : "${REAPER_ACTION_CMD:?REAPER_ACTION_CMD must be set}"
    local dry_run="${REAPER_DRY_RUN:-true}"
    local lock_dir="${REAPER_LOCK_DIR:-.chump-locks}"

    local reaped=0
    local skipped=0
    local candidate

    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue

        if eval "$REAPER_PREDICATE_CMD"; then
            if [[ "$dry_run" == "true" ]]; then
                echo "  WOULD REAP: $candidate"
            else
                eval "$REAPER_ACTION_CMD"
                echo "  REAPED: $candidate"
            fi
            reaped=$((reaped + 1))
        else
            skipped=$((skipped + 1))
        fi
    done < <(eval "$REAPER_FIND_CMD")

    echo
    echo "$REAPER_NAME: reaped=$reaped skipped=$skipped dry_run=$dry_run"

    if [[ "$dry_run" == "false" && "$reaped" -gt 0 && -n "${REAPER_AMBIENT_KIND:-}" ]]; then
        printf '{"ts":"%s","kind":"%s","count":%d}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REAPER_AMBIENT_KIND" "$reaped" \
            >> "$lock_dir/ambient.jsonl" 2>/dev/null || true
    fi

    REAPER_ENGINE_REAPED="$reaped"
    REAPER_ENGINE_SKIPPED="$skipped"
}
