#!/usr/bin/env bash
# inbox-glance-act.sh — the "Glance" phase addendum (INFRA-1798).
#
# Receive-and-act-by-default, loop-discipline half (sibling of CREDIBLE-114,
# the PreToolUse hard-enforcement half). Per A2A_MASTER_PLAN_2026-06-03
# Tier-0 step 0.3: `chump-inbox.sh read` must be the MANDATORY first step of
# every curator/worker/autopilot cycle, and the agent must ACT on what it
# finds — not read-only.
#
# Source this file; do not execute directly. Call `chump_glance_and_act` as
# the FIRST step of any loop's tick/cycle, before picking new work.
#
# What it does, in order:
#   1. Drains the inbox via the canonical scripts/coord/chump-inbox.sh read
#      (advances the cursor; chump-inbox.sh itself emits kind=inbox_advance
#      with the drained count — this file does NOT re-emit that).
#   2. Acts on each drained item:
#        - event=HANDOFF or event=STUCK → ack the sender with
#          broadcast.sh --to <sender> DONE <gap>
#   3. Scans the last CHUMP_GLANCE_PROPOSAL_WINDOW lines of ambient.jsonl for
#      open `event=FEEDBACK kind=proposal` corr_ids this session has not yet
#      voted on, and casts `chump vote <corr_id> 0 --reason ...` (abstain —
#      a generic glance pass has no lane-specific opinion; lane-specific
#      reactors, e.g. handoff-loop.sh's react-feedback, may vote non-zero
#      before this runs and this step is a no-op for those corr_ids since
#      _already_voted() finds the prior vote).
#
# Requires: CHUMP_SESSION_ID (or falls back the same way chump-inbox.sh
# does), CHUMP_FLEET_RECV_SIDE_V0=1 to actually cast votes (else step 3 is
# skipped — voting stays feature-flagged, per META-159).
#
# bash 3.2-compatible (macOS system bash), no associative arrays.

_glance_repo_root() {
    if [[ -n "${REPO_ROOT:-}" ]]; then
        printf '%s' "$REPO_ROOT"
        return
    fi
    git rev-parse --show-toplevel 2>/dev/null || pwd
}

_glance_lock_dir() {
    if [[ -n "${LOCK_DIR:-}" ]]; then
        printf '%s' "$LOCK_DIR"
        return
    fi
    printf '%s/.chump-locks' "$(_glance_repo_root)"
}

_glance_session_id() {
    local sid="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
    if [[ -z "$sid" ]]; then
        local lock_dir; lock_dir="$(_glance_lock_dir)"
        [[ -f "$lock_dir/.wt-session-id" ]] && sid="$(cat "$lock_dir/.wt-session-id" 2>/dev/null || true)"
    fi
    if [[ -z "$sid" && -f "$HOME/.chump/session_id" ]]; then
        sid="$(cat "$HOME/.chump/session_id" 2>/dev/null || true)"
    fi
    printf '%s' "${sid:-unknown-session}"
}

# Has this session already voted on corr_id? Scans ambient for a
# kind=vote line with matching corr_id + session.
_glance_already_voted() {
    local ambient="$1" corr_id="$2" session="$3"
    [[ -f "$ambient" ]] || return 1
    grep -F "\"corr_id\":\"${corr_id}\"" "$ambient" 2>/dev/null \
        | grep -F '"kind":"vote"' \
        | grep -qF "\"session\":\"${session}\""
}

# chump_glance_and_act [--dry-run]
#
# Prints a short human-readable summary. Sets globals on return:
#   GLANCE_ITEMS_READ, GLANCE_ACKS_SENT, GLANCE_VOTES_CAST
chump_glance_and_act() {
    local dry_run=0
    [[ "${1:-}" == "--dry-run" ]] && dry_run=1

    local repo_root; repo_root="$(_glance_repo_root)"
    local lock_dir; lock_dir="$(_glance_lock_dir)"
    local session; session="$(_glance_session_id)"
    local ambient="$lock_dir/ambient.jsonl"
    local inbox_script="$repo_root/scripts/coord/chump-inbox.sh"
    local broadcast_script="$repo_root/scripts/coord/broadcast.sh"

    GLANCE_ITEMS_READ=0
    GLANCE_ACKS_SENT=0
    GLANCE_VOTES_CAST=0

    echo "## Glance: inbox drain + act (session=${session})"

    # ── Step 1: drain inbox via the canonical script (advances cursor,
    #    emits kind=inbox_advance itself). ─────────────────────────────────
    # NOTE: deliberately NOT --json — that mode pretty-prints a JSON array
    # (indent=2, multi-line), which breaks the one-object-per-line parsing
    # below. Plain `read` prints one compact json.dumps(m) per line.
    local drained=""
    if [[ -x "$inbox_script" ]]; then
        drained="$(CHUMP_SESSION_ID="$session" LOCK_DIR="$lock_dir" \
            bash "$inbox_script" read 2>/dev/null || true)"
    fi

    if [[ -z "$drained" ]]; then
        echo "  (inbox empty)"
    else
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            GLANCE_ITEMS_READ=$((GLANCE_ITEMS_READ + 1))

            local ev from gap
            ev="$(printf '%s' "$line" | grep -o '"event":"[^"]*"' | head -1 | sed 's/"event":"//;s/"$//')"
            from="$(printf '%s' "$line" | grep -o '"session":"[^"]*"' | head -1 | sed 's/"session":"//;s/"$//')"
            gap="$(printf '%s' "$line" | grep -o '"gap":"[^"]*"' | head -1 | sed 's/"gap":"//;s/"$//')"

            case "$ev" in
                HANDOFF|STUCK)
                    if [[ -n "$from" && -n "$gap" ]]; then
                        echo "  [act] ack ${ev} gap=${gap} from=${from} → DONE"
                        if [[ "$dry_run" -eq 0 && -x "$broadcast_script" ]]; then
                            CHUMP_SESSION_ID="$session" LOCK_DIR="$lock_dir" \
                                bash "$broadcast_script" --to "$from" DONE "$gap" >/dev/null 2>&1 || true
                        fi
                        GLANCE_ACKS_SENT=$((GLANCE_ACKS_SENT + 1))
                    fi
                    ;;
                *)
                    ;;
            esac
        done <<< "$drained"
    fi

    # ── Step 2: vote on open proposals not yet voted by this session. ─────
    # Skippable via CHUMP_GLANCE_SKIP_VOTE=1 — the deliberator role tallies
    # votes and must stay neutral, so it drains + acks but never votes.
    if [[ "${CHUMP_GLANCE_SKIP_VOTE:-0}" != "1" && "${CHUMP_FLEET_RECV_SIDE_V0:-0}" == "1" ]]; then
        local window="${CHUMP_GLANCE_PROPOSAL_WINDOW:-300}"
        if [[ -f "$ambient" ]]; then
            local corr_ids
            corr_ids="$(tail -n "$window" "$ambient" 2>/dev/null \
                | grep -F '"event":"FEEDBACK"' \
                | grep -F '"kind":"proposal"' \
                | grep -o '"corr_id":"[^"]*"' \
                | sed 's/"corr_id":"//;s/"$//' \
                | sort -u)"
            local corr_id
            while IFS= read -r corr_id; do
                [[ -z "$corr_id" ]] && continue
                if _glance_already_voted "$ambient" "$corr_id" "$session"; then
                    continue
                fi
                echo "  [act] vote 0 (abstain) on unvoted proposal corr_id=${corr_id}"
                if [[ "$dry_run" -eq 0 ]] && command -v chump >/dev/null 2>&1; then
                    CHUMP_SESSION_ID="$session" \
                        chump vote "$corr_id" 0 --reason "glance: no lane-specific opinion, abstaining to unblock quorum" \
                        2>/dev/null || true
                fi
                GLANCE_VOTES_CAST=$((GLANCE_VOTES_CAST + 1))
            done <<< "$corr_ids"
        fi
    fi

    echo "  items_read=${GLANCE_ITEMS_READ} acks_sent=${GLANCE_ACKS_SENT} votes_cast=${GLANCE_VOTES_CAST}"
    return 0
}
