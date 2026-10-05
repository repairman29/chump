#!/usr/bin/env bash
# inbox-glance.sh — the mandatory "Glance" phase (INFRA-1798).
#
# A2A_MASTER_PLAN_2026-06-03 Tier-0 step 0.3: `chump-inbox.sh read` must be
# the FIRST step of every curator/worker/autopilot cycle, and the agent must
# ACT on what it finds — not read-only. 57 proposals were broadcast over 24
# days with zero votes because nothing was draining + reacting to inboxes on
# a cadence; consensus_result stayed at 0 (CREDIBLE-122 fixed the tally-side
# closing bug — this fixes the read-side that never fed it).
#
# Provides one function:
#   chump_inbox_glance <role>
#     1. Drains this session's inbox via chump-inbox.sh read --json (which
#        itself advances the cursor + emits kind=inbox_advance — AC #3).
#     2. Acts on every drained item (AC #2):
#          - HANDOFF / STUCK  -> ack the sender: broadcast.sh --to <sender> DONE
#          - FEEDBACK kind=proposal -> chump vote <corr_id> +1|-1|0 --reason,
#            once per corr_id per session (tracked in a small voted-log so
#            repeat glances don't re-vote). Default vote is abstain (0) with
#            a reason — callers with real judgement (e.g. handoff-loop.sh's
#            schema-aware react-feedback) should vote directly and this
#            glance step will see the corr_id already logged and skip it.
#     Always returns 0 — a glance failure must never abort the caller's cycle.
#
# Source this file; do not execute directly.
# bash 3.2-compatible (macOS system bash).
#
# Env:
#   CHUMP_SESSION_ID   session id (defaults per chump-inbox.sh's own resolution)
#   CHUMP_LOCK_DIR     override .chump-locks location (tests)
#   CHUMP_AMBIENT_LOG  override ambient.jsonl path (tests)

_ig_coord_dir() {
    cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

_ig_lock_dir() {
    # Honour the same bare LOCK_DIR env override chump-inbox.sh /
    # inbox-routing.sh use (tests + synthetic workspaces), plus a
    # CHUMP_LOCK_DIR alias for callers that prefer the prefixed form.
    if [[ -n "${LOCK_DIR:-}" ]]; then
        printf '%s' "$LOCK_DIR"
        return
    fi
    if [[ -n "${CHUMP_LOCK_DIR:-}" ]]; then
        printf '%s' "$CHUMP_LOCK_DIR"
        return
    fi
    local repo; repo="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    local git_common; git_common="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    local main_repo
    if [[ "$git_common" == ".git" ]]; then
        main_repo="$repo"
    else
        main_repo="$(cd "$git_common/.." && pwd)"
    fi
    printf '%s/.chump-locks' "$main_repo"
}

chump_inbox_glance() {
    local role="${1:-fleet}"
    local coord_dir; coord_dir="$(_ig_coord_dir)"
    local inbox_script="$coord_dir/chump-inbox.sh"
    local broadcast_script="$coord_dir/broadcast.sh"
    [[ -x "$inbox_script" ]] || return 0

    local lock_dir; lock_dir="$(_ig_lock_dir)"
    local voted_log="$lock_dir/inbox-glance-voted.${role}.log"
    mkdir -p "$lock_dir" 2>/dev/null || true
    touch "$voted_log" 2>/dev/null || true

    local items_json
    items_json="$("$inbox_script" read --json 2>/dev/null || echo "[]")"
    [[ -z "$items_json" ]] && items_json="[]"
    [[ "$items_json" == "[]" ]] && return 0

    local acted=0
    # Field separator is \x1f (unit separator), NOT tab: bash `read` treats
    # tab as IFS-whitespace and silently collapses consecutive tab
    # delimiters (empty fields vanish, shifting later columns left), even
    # when IFS is set to tab-only. \x1f has no such special-casing.
    while IFS=$'\x1f' read -r ev sender to corr_id gap; do
        [[ -z "$ev" ]] && continue
        case "$ev" in
            HANDOFF|STUCK)
                if [[ -n "$sender" && -x "$broadcast_script" ]]; then
                    "$broadcast_script" --to "$sender" DONE "${gap:--}" "glance-ack:${role}" \
                        >/dev/null 2>&1 || true
                    acted=1
                fi
                ;;
            FEEDBACK:proposal)
                [[ -n "$corr_id" ]] || continue
                grep -qxF "$corr_id" "$voted_log" 2>/dev/null && continue
                if command -v chump >/dev/null 2>&1; then
                    chump vote "$corr_id" 0 \
                        --reason "glance(${role}): auto-abstain on drain, out-of-lane or unreviewed" \
                        >/dev/null 2>&1 || true
                fi
                printf '%s\n' "$corr_id" >> "$voted_log" 2>/dev/null || true
                acted=1
                ;;
        esac
    done < <(printf '%s' "$items_json" | python3 -c '
import json, sys
try:
    items = json.load(sys.stdin)
except Exception:
    items = []
if not isinstance(items, list):
    items = []
for m in items:
    ev = m.get("event") or m.get("kind") or ""
    if ev == "FEEDBACK" and (m.get("kind") == "proposal"):
        ev = "FEEDBACK:proposal"
    sender = m.get("session") or m.get("from") or ""
    to = m.get("to") or ""
    corr = m.get("corr_id") or ""
    gap = m.get("gap") or ""
    print("\x1f".join([ev, sender, to, corr, gap]))
' 2>/dev/null)

    return 0
}
