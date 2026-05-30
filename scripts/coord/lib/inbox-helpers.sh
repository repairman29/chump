#!/usr/bin/env bash
# scripts/coord/lib/inbox-helpers.sh — META-161 / META-157 Phase 0 shared helpers
#
# Provides _drain_inbox and _peek_pending_feedback for curator loops that
# implement the Phase 0 inbox-drain pattern (FLEET_RECV_SIDE_2026-05-30 §3).
#
# Source this file; then call the two helpers at the top of each tick subcommand:
#
#   source "$SCRIPT_DIR/lib/inbox-helpers.sh"
#
#   if [[ "${CHUMP_FLEET_RECV_SIDE_V0:-0}" == "1" ]]; then
#       _phase0_inbox_drain "$LOCK_DIR" "$SESSION_ID" "$AMBIENT" "$LOOP_TAG" actionable
#   fi
#
# Callers MUST have these variables in scope before sourcing:
#   (none — all state is passed as arguments)
#
# Exported helpers:
#   _drain_inbox LOCK_DIR SESSION_ID        — reads inbox, returns count via stdout
#   _peek_pending_feedback AMBIENT           — greps ambient for FEEDBACK proposals
#   _phase0_inbox_drain LOCK_DIR SESSION_ID AMBIENT LOOP_TAG nameref_actionable
#       Combined Phase 0 block. Sets nameref_actionable=1 when items found.
#       Prints the ## Phase 0 header + items or "(none)".
#
# Feature flag: CHUMP_FLEET_RECV_SIDE_V0=1 — callers check this; helpers themselves
# do NOT check it (single-responsibility).
#
# Rust-First-Bypass: <200 LOC, glue between tail + grep; no state mutation beyond
# ambient.jsonl emits that callers already own. No state-db writes.

# _drain_inbox — reads $LOCK_DIR/inbox/$SESSION_ID.jsonl (last 5 lines).
# Outputs the items to stdout; caller counts non-empty lines.
# Non-advancing peek (does NOT advance cursor — idempotent).
_drain_inbox() {
    local lock_dir="$1"
    local session_id="$2"
    local inbox_file="$lock_dir/inbox/${session_id}.jsonl"
    if [[ -f "$inbox_file" ]]; then
        tail -5 "$inbox_file" 2>/dev/null || true
    fi
}

# _peek_pending_feedback — scan last 200 lines of AMBIENT for
# kind=FEEDBACK or kind=proposal events whose corr_id does NOT appear in
# a kind=consensus_result within the same window.
# Outputs matching JSON lines to stdout.
_peek_pending_feedback() {
    local ambient="$1"
    if [[ ! -f "$ambient" ]]; then
        return 0
    fi

    # Collect corr_ids that already have a consensus_result in the window
    local window_lines
    window_lines="$(tail -200 "$ambient" 2>/dev/null || true)"

    local resolved_ids
    resolved_ids="$(printf '%s\n' "$window_lines" \
        | grep '"kind":"consensus_result"' \
        | grep -o '"corr_id":"[^"]*"' \
        | sed 's/"corr_id":"//; s/"//' \
        || true)"

    # Print FEEDBACK/proposal lines whose corr_id is NOT in resolved set
    printf '%s\n' "$window_lines" \
        | grep -E '"kind":"(FEEDBACK|proposal)"' \
        | while IFS= read -r line; do
            local cid
            cid="$(printf '%s' "$line" | grep -o '"corr_id":"[^"]*"' | sed 's/"corr_id":"//; s/"//' || true)"
            if [[ -z "$cid" ]]; then
                # No corr_id — surface it (unmatched)
                printf '%s\n' "$line"
            elif ! printf '%s\n' "$resolved_ids" | grep -qxF "$cid"; then
                printf '%s\n' "$line"
            fi
        done || true
}

# _phase0_inbox_drain — combined Phase 0 block for tick subcommands.
# Args:
#   $1 lock_dir
#   $2 session_id
#   $3 ambient
#   $4 loop_tag   (e.g. "external-collab", "infra-watcher")
#   $5 nameref    name of caller's actionable integer variable (bash 4.3+ namerefs)
#
# Side-effects: prints headers + items to stdout; sets caller's actionable var.
#
# Bash 3.2 compat note: macOS ships bash 3.2 which lacks namerefs (declare -n).
# We use eval instead for the assignment.
_phase0_inbox_drain() {
    local lock_dir="$1"
    local session_id="$2"
    local ambient="$3"
    local loop_tag="$4"
    local actionable_var="$5"

    echo "## Phase 0: inbox-drain + feedback-peek (${loop_tag})"

    # -- inbox --
    local inbox_items
    inbox_items="$(_drain_inbox "$lock_dir" "$session_id")"
    local inbox_count=0
    if [[ -n "$inbox_items" ]]; then
        inbox_count="$(printf '%s\n' "$inbox_items" | grep -c . || true)"
        printf '%s\n' "$inbox_items"
    else
        echo "  inbox: (none)"
    fi

    # -- feedback --
    local feedback_items
    feedback_items="$(_peek_pending_feedback "$ambient")"
    local feedback_count=0
    local feedback_corr_ids=""
    if [[ -n "$feedback_items" ]]; then
        feedback_count="$(printf '%s\n' "$feedback_items" | grep -c . || true)"
        echo "## Pending FEEDBACK requiring vote"
        printf '%s\n' "$feedback_items"
        # Extract corr_ids for summary line
        feedback_corr_ids="$(printf '%s\n' "$feedback_items" \
            | grep -o '"corr_id":"[^"]*"' \
            | sed 's/"corr_id":"//; s/"//' \
            | tr '\n' ',' \
            | sed 's/,$//' \
            || true)"
        if [[ -n "$feedback_corr_ids" ]]; then
            echo "  corr_ids: ${feedback_corr_ids}"
        fi
    else
        echo "  feedback: (none)"
    fi

    # Set actionable in caller scope
    if (( inbox_count > 0 || feedback_count > 0 )); then
        eval "${actionable_var}=1"
    fi
}
