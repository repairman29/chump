#!/usr/bin/env bash
# scripts/coord/deliberator-loop.sh — Chump curator-opus-deliberator role CLI (harness-neutral)
#
# Productizes the curator-opus-deliberator role per META-162.
# Any harness (Claude Code, opencode-bigpickle, codex, manual) invokes this
# the same way. The .claude/agents/deliberator.md + .claude/skills/deliberator/
# wrappers delegate here; they are convenience, not capability.
#
# This role owns fleet consensus: tallying FEEDBACK kind=vote events, emitting
# kind=consensus_result when a verdict is reached, and escalating NO_QUORUM
# proposals to the operator after deadline+24h.
#
# Sub-slice E of META-157 (fleet recv-side v0). See:
#   docs/strategy/FLEET_RECV_SIDE_2026-05-30.md §3 Slice 5
#   docs/gaps/META-162.yaml — 9 AC
#   docs/gaps/META-159.yaml — sibling: chump vote + consensus-tally CLI
#
# Feature flag: CHUMP_FLEET_RECV_SIDE_V0=1 required for tick to do real work.
# Without it, tick emits a heartbeat-only response.
#
# Rust-First-Bypass: glue between jq + scripts/coord helpers;
# <200 LOC at first commit; read-mostly (only writes are ambient.jsonl emit
# lines, already-idempotent). Will be ported to Rust if the surface grows
# past 200 LOC or requires shared state mutation beyond ambient.
#
# Usage:
#   scripts/coord/deliberator-loop.sh <subcommand> [args]
#
# Subcommands:
#   tick          One full work-your-lane cycle: read inbox, scan ambient for
#                 unresolved proposals, compute verdicts, emit consensus_result
#                 or escalate NO_QUORUM to operator.
#                 Exit 0 if actionable, exit 1 if quiet, exit 2 on bad input.
#   audit         Force-tally all pending proposals now (ignore deadline).
#                 Optional: --corr-id <id> to tally a single proposal.
#                 Exit 0 ok, exit 1 quiet.
#   heartbeat     Emit kind=deliberator_heartbeat to ambient.jsonl. Exit 0.
#   help          Print this.
#
# Exit codes:
#   0 — success / actionable items found
#   1 — quiet (no actionable items)
#   2 — bad subcommand or missing required arg
#   3 — ambient log missing or unreadable
#
# Env:
#   CHUMP_FLEET_RECV_SIDE_V0      set to "1" to enable real tally work
#   CHUMP_SESSION_ID              session id for inbox + emits (default: deliberator-<pid>)
#   CHUMP_AMBIENT_LOG             ambient.jsonl path override
#   CHUMP_DELIBERATOR_LANE_OVERRIDE  if "1", lane-scope checks skip
#   CHUMP_PROPOSAL_WINDOW_HOURS   how far back to scan for proposals (default: 24)
#   CHUMP_NO_QUORUM_GRACE_HOURS   grace hours past deadline before escalation (default: 24)

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
SESSION_ID="${CHUMP_SESSION_ID:-deliberator-$$}"
PROPOSAL_WINDOW_HOURS="${CHUMP_PROPOSAL_WINDOW_HOURS:-24}"
NO_QUORUM_GRACE_HOURS="${CHUMP_NO_QUORUM_GRACE_HOURS:-24}"

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_now_epoch() { date -u +%s; }

# ── Helpers ──────────────────────────────────────────────────────────────────

# Emit an ambient line.
_emit_kind() {
    local kind="$1"; shift
    local extra="${1:-}"
    mkdir -p "$LOCK_DIR" 2>/dev/null || true
    local body
    if [[ -n "$extra" ]]; then
        body="$(printf '{"ts":"%s","kind":"%s","session":"%s",%s}' \
            "$(_now_iso)" "$kind" "$SESSION_ID" "$extra")"
    else
        body="$(printf '{"ts":"%s","kind":"%s","session":"%s"}' \
            "$(_now_iso)" "$kind" "$SESSION_ID")"
    fi
    printf '%s\n' "$body" >> "$AMBIENT" 2>/dev/null || true
}

# Check if jq is available.
_have_jq() { command -v jq >/dev/null 2>&1; }

# Parse a field from a JSON line using jq (falls back to grep+sed).
_jq_field() {
    local line="$1" field="$2"
    if _have_jq; then
        printf '%s' "$line" | jq -r ".$field // empty" 2>/dev/null || true
    else
        printf '%s' "$line" | grep -o "\"${field}\":\"[^\"]*\"" \
            | sed "s/\"${field}\":\"//;s/\"//" | head -1 || true
    fi
}

# Parse a numeric field from a JSON line.
_jq_num() {
    local line="$1" field="$2"
    if _have_jq; then
        printf '%s' "$line" | jq -r ".$field // 0" 2>/dev/null || echo "0"
    else
        printf '%s' "$line" | grep -o "\"${field}\":[0-9-]*" \
            | sed "s/\"${field}\"://" | head -1 || echo "0"
    fi
}

# Convert ISO8601 timestamp to epoch seconds (macOS + Linux compatible).
_iso_to_epoch() {
    local ts="$1"
    # macOS date: -u flag ensures the Z-suffix UTC timestamp is parsed as UTC.
    if date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null; then
        return
    fi
    # GNU date
    if date -d "$ts" +%s 2>/dev/null; then
        return
    fi
    # python3 fallback (always available on macOS + modern Linux)
    python3 -c "
import datetime, sys
ts = sys.argv[1]
dt = datetime.datetime.fromisoformat(ts.replace('Z', '+00:00'))
print(int(dt.timestamp()))
" "$ts" 2>/dev/null || echo "0"
}

# Read inbox items for this session (non-advancing peek).
_peek_inbox() {
    local inbox_file="$LOCK_DIR/inbox/${SESSION_ID}.jsonl"
    if [[ -f "$inbox_file" ]]; then
        tail -5 "$inbox_file" 2>/dev/null || true
    fi
}

# ── Verdict logic (canonical from META-159 AC #3) ────────────────────────────
# Inputs: yes no abstain total deadline_epoch now_epoch
# Outputs: prints verdict string to stdout
_compute_verdict() {
    local yes="$1" no="$2" total="$3"
    local deadline_epoch="$4" now_epoch="$5"

    local verdict
    if (( yes >= 3 && yes > no )); then
        verdict="PASSED"
    elif (( no > yes && no >= 2 )); then
        verdict="FAILED"
    elif (( total < 3 )); then
        verdict="NO_QUORUM"
    else
        verdict="NO_QUORUM"
    fi

    # EXTENDED: verdict is deterministic but deadline is still in the future
    if [[ "$verdict" != "NO_QUORUM" ]] && (( deadline_epoch > now_epoch )); then
        verdict="EXTENDED"
    fi

    printf '%s' "$verdict"
}

# ── Tally votes for a single corr_id ─────────────────────────────────────────
# Tries chump consensus-tally first (META-159); falls back to inline logic.
# Prints JSON: {"verdict":"...","yes":N,"no":N,"abstain":N,"total":N,"voters":[...]}
_tally_corr_id() {
    local corr_id="$1"
    local deadline_epoch="${2:-0}"
    local now_epoch
    now_epoch="$(_now_epoch)"

    # Try chump consensus-tally if available (META-159).
    if command -v chump >/dev/null 2>&1 \
        && chump consensus-tally --help 2>&1 | grep -q "corr-id" 2>/dev/null; then
        local tally_out
        tally_out="$(CHUMP_FLEET_RECV_SIDE_V0=1 chump consensus-tally \
            --corr-id "$corr_id" --since "${PROPOSAL_WINDOW_HOURS}h" 2>/dev/null || true)"
        if [[ -n "$tally_out" ]]; then
            printf '%s' "$tally_out"
            return 0
        fi
    fi

    # Inline fallback: scan ambient for FEEDBACK kind=vote events for this corr_id.
    local yes=0 no=0 abstain=0 total=0
    local voters=()
    local window_cutoff
    window_cutoff=$(( now_epoch - PROPOSAL_WINDOW_HOURS * 3600 ))

    if [[ ! -f "$AMBIENT" ]]; then
        printf '{"verdict":"NO_QUORUM","yes":0,"no":0,"abstain":0,"total":0,"voters":[]}'
        return 0
    fi

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Filter for FEEDBACK kind=vote events matching our corr_id.
        local line_kind line_corr line_event
        line_event="$(_jq_field "$line" "event")"
        line_kind="$(_jq_field "$line" "kind")"
        line_corr="$(_jq_field "$line" "corr_id")"
        [[ "$line_event" != "FEEDBACK" ]] && continue
        [[ "$line_kind" != "vote" ]] && continue
        [[ "$line_corr" != "$corr_id" ]] && continue

        # Check timestamp is within window.
        local line_ts line_epoch
        line_ts="$(_jq_field "$line" "ts")"
        line_epoch="$(_iso_to_epoch "$line_ts")"
        (( line_epoch < window_cutoff )) && continue

        local vote_val voter
        vote_val="$(_jq_num "$line" "vote")"
        voter="$(_jq_field "$line" "session")"

        if (( vote_val > 0 )); then
            (( yes++ )) || true
        elif (( vote_val < 0 )); then
            (( no++ )) || true
        else
            (( abstain++ )) || true
        fi
        (( total++ )) || true
        voters+=("\"${voter}\"")
    done < "$AMBIENT"

    local verdict
    verdict="$(_compute_verdict "$yes" "$no" "$total" "$deadline_epoch" "$now_epoch")"

    local voters_json
    if (( ${#voters[@]} == 0 )); then
        voters_json="[]"
    else
        voters_json="[$(IFS=,; echo "${voters[*]}")]"
    fi

    printf '{"verdict":"%s","yes":%d,"no":%d,"abstain":%d,"total":%d,"voters":%s}' \
        "$verdict" "$yes" "$no" "$abstain" "$total" "$voters_json"
}

# Check if a consensus_result already exists for this corr_id (idempotency).
_has_consensus_result() {
    local corr_id="$1"
    [[ -f "$AMBIENT" ]] || return 1
    grep -q "\"kind\":\"consensus_result\".*\"corr_id\":\"${corr_id}\"" "$AMBIENT" 2>/dev/null \
        || grep -q "\"corr_id\":\"${corr_id}\".*\"kind\":\"consensus_result\"" "$AMBIENT" 2>/dev/null
}

# ── Subcommands ──────────────────────────────────────────────────────────────

_cmd_tick() {
    echo "=== curator-opus-deliberator tick @ $(_now_iso) ==="
    echo

    # Feature flag gate.
    if [[ "${CHUMP_FLEET_RECV_SIDE_V0:-0}" != "1" ]]; then
        echo "[deliberator] CHUMP_FLEET_RECV_SIDE_V0 not set — heartbeat only"
        _cmd_heartbeat
        return 1
    fi

    local actionable=0

    # Phase 1: Inbox check.
    echo "## Inbox (last 5 items for session ${SESSION_ID})"
    local inbox_items
    inbox_items="$(_peek_inbox)"
    if [[ -n "$inbox_items" ]]; then
        printf '%s\n' "$inbox_items"
        actionable=1
    else
        echo "  (no inbox items)"
    fi
    echo

    # Phase 2: Scan ambient for FEEDBACK kind=proposal events.
    echo "## Pending proposals (last ${PROPOSAL_WINDOW_HOURS}h)"

    if [[ ! -f "$AMBIENT" ]]; then
        echo "  [deliberator] ambient log not found at $AMBIENT" >&2
        return 3
    fi

    local now_epoch
    now_epoch="$(_now_epoch)"
    local window_cutoff
    window_cutoff=$(( now_epoch - PROPOSAL_WINDOW_HOURS * 3600 ))

    local proposals_found=0
    local resolved=0
    local escalated=0

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local line_event line_kind line_corr
        line_event="$(_jq_field "$line" "event")"
        line_kind="$(_jq_field "$line" "kind")"
        [[ "$line_event" != "FEEDBACK" ]] && continue
        [[ "$line_kind" != "proposal" ]] && continue

        line_corr="$(_jq_field "$line" "corr_id")"
        [[ -z "$line_corr" ]] && continue

        # Filter to window.
        local line_ts line_epoch
        line_ts="$(_jq_field "$line" "ts")"
        line_epoch="$(_iso_to_epoch "$line_ts")"
        (( line_epoch < window_cutoff )) && continue

        proposals_found=1

        # Idempotency: skip if already resolved.
        if _has_consensus_result "$line_corr"; then
            echo "  corr_id=${line_corr} — already resolved, skipping"
            continue
        fi

        # Extract deadline from proposal event (default: proposal_ts + 48h).
        local deadline_str deadline_epoch
        deadline_str="$(_jq_field "$line" "deadline")"
        if [[ -n "$deadline_str" ]]; then
            deadline_epoch="$(_iso_to_epoch "$deadline_str")"
        else
            deadline_epoch=$(( line_epoch + 48 * 3600 ))
        fi

        # Tally votes.
        local tally_json
        tally_json="$(_tally_corr_id "$line_corr" "$deadline_epoch")"

        local verdict yes no abstain total voters_json
        verdict="$(_jq_field "$tally_json" "verdict")"
        yes="$(_jq_num "$tally_json" "yes")"
        no="$(_jq_num "$tally_json" "no")"
        abstain="$(_jq_num "$tally_json" "abstain")"
        total="$(_jq_num "$tally_json" "total")"
        voters_json="$( _have_jq \
            && printf '%s' "$tally_json" | jq -c '.voters // []' 2>/dev/null \
            || echo "[]" )"

        echo "  corr_id=${line_corr} verdict=${verdict} yes=${yes} no=${no} abstain=${abstain} total=${total}"

        if [[ "$verdict" == "PASSED" || "$verdict" == "FAILED" ]]; then
            # Emit consensus_result.
            local extra
            extra="$(printf '"event":"FEEDBACK","corr_id":"%s","verdict":"%s","vote_counts":{"yes":%s,"no":%s,"abstain":%s,"total":%s},"voters_list":%s' \
                "$line_corr" "$verdict" "$yes" "$no" "$abstain" "$total" "$voters_json")"
            _emit_kind "consensus_result" "$extra"
            # scanner-anchor: "kind":"consensus_result"
            echo "    → emitted kind=consensus_result verdict=${verdict}"
            (( resolved++ )) || true
            (( actionable++ )) || true

        elif [[ "$verdict" == "NO_QUORUM" ]]; then
            # Check if deadline+NO_QUORUM_GRACE_HOURS has elapsed.
            local grace_cutoff
            grace_cutoff=$(( deadline_epoch + NO_QUORUM_GRACE_HOURS * 3600 ))
            if (( now_epoch >= grace_cutoff )); then
                echo "    → NO_QUORUM + deadline+${NO_QUORUM_GRACE_HOURS}h elapsed — escalating to operator"
                local recall_reason="fleet_no_quorum corr_id=${line_corr}"
                if [[ -f "$MAIN_REPO/scripts/dispatch/operator-recall.sh" ]]; then
                    bash "$MAIN_REPO/scripts/dispatch/operator-recall.sh" \
                        --reason "$recall_reason" 2>/dev/null || true
                else
                    # Fallback: emit ambient event as operator signal.
                    _emit_kind "operator_recall" \
                        "\"reason\":\"${recall_reason}\",\"escalated_by\":\"deliberator\""
                    # scanner-anchor: "kind":"operator_recall"
                fi
                (( escalated++ )) || true
                (( actionable++ )) || true
            else
                local remaining=$(( (grace_cutoff - now_epoch) / 3600 ))
                echo "    → NO_QUORUM — grace window ${remaining}h remaining before escalation"
            fi

        elif [[ "$verdict" == "EXTENDED" ]]; then
            local remaining=$(( (deadline_epoch - now_epoch) / 3600 ))
            echo "    → EXTENDED — ${remaining}h until deadline"
        fi

    done < "$AMBIENT"

    echo
    if (( proposals_found == 0 )); then
        echo "[deliberator] tick: no pending proposals in last ${PROPOSAL_WINDOW_HOURS}h"
    else
        echo "[deliberator] tick: resolved=${resolved} escalated=${escalated}"
    fi

    if (( actionable > 0 )); then
        return 0
    fi
    return 1
}

_cmd_audit() {
    # Parse optional --corr-id flag.
    local filter_corr=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --corr-id) filter_corr="$2"; shift 2 ;;
            *) echo "[deliberator] unknown audit arg: $1" >&2; exit 2 ;;
        esac
    done

    echo "=== curator-opus-deliberator audit @ $(_now_iso) ==="
    if [[ -n "$filter_corr" ]]; then
        echo "## Force-tallying corr_id=${filter_corr}"
    else
        echo "## Force-tallying all pending proposals"
    fi
    echo

    if [[ ! -f "$AMBIENT" ]]; then
        echo "[deliberator] ambient log not found at $AMBIENT" >&2
        return 3
    fi

    local now_epoch
    now_epoch="$(_now_epoch)"
    local found=0

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local line_event line_kind line_corr
        line_event="$(_jq_field "$line" "event")"
        line_kind="$(_jq_field "$line" "kind")"
        [[ "$line_event" != "FEEDBACK" ]] && continue
        [[ "$line_kind" != "proposal" ]] && continue

        line_corr="$(_jq_field "$line" "corr_id")"
        [[ -z "$line_corr" ]] && continue

        # Filter by corr_id if requested.
        if [[ -n "$filter_corr" && "$line_corr" != "$filter_corr" ]]; then
            continue
        fi

        # Skip already-resolved (audit ignores deadline, not idempotency).
        if _has_consensus_result "$line_corr"; then
            echo "  corr_id=${line_corr} — already resolved"
            continue
        fi

        local line_ts line_epoch deadline_epoch
        line_ts="$(_jq_field "$line" "ts")"
        line_epoch="$(_iso_to_epoch "$line_ts")"
        local deadline_str
        deadline_str="$(_jq_field "$line" "deadline")"
        if [[ -n "$deadline_str" ]]; then
            deadline_epoch="$(_iso_to_epoch "$deadline_str")"
        else
            deadline_epoch=$(( line_epoch + 48 * 3600 ))
        fi

        local tally_json
        # Force deadline to past so EXTENDED resolves to real verdict.
        tally_json="$(_tally_corr_id "$line_corr" "$(( now_epoch - 1 ))")"

        local verdict yes no abstain total voters_json
        verdict="$(_jq_field "$tally_json" "verdict")"
        yes="$(_jq_num "$tally_json" "yes")"
        no="$(_jq_num "$tally_json" "no")"
        abstain="$(_jq_num "$tally_json" "abstain")"
        total="$(_jq_num "$tally_json" "total")"
        voters_json="$( _have_jq \
            && printf '%s' "$tally_json" | jq -c '.voters // []' 2>/dev/null \
            || echo "[]" )"

        echo "  corr_id=${line_corr} verdict=${verdict} yes=${yes} no=${no} abstain=${abstain} total=${total}"

        if [[ "$verdict" == "PASSED" || "$verdict" == "FAILED" ]]; then
            local extra
            extra="$(printf '"event":"FEEDBACK","corr_id":"%s","verdict":"%s","vote_counts":{"yes":%s,"no":%s,"abstain":%s,"total":%s},"voters_list":%s' \
                "$line_corr" "$verdict" "$yes" "$no" "$abstain" "$total" "$voters_json")"
            _emit_kind "consensus_result" "$extra"
            echo "    → emitted kind=consensus_result verdict=${verdict}"
        fi

        found=1
    done < "$AMBIENT"

    if (( found == 0 )); then
        echo "[deliberator] audit: no pending proposals found"
        return 1
    fi
    echo
    echo "[deliberator] audit complete"
    return 0
}

_cmd_heartbeat() {
    _emit_kind "deliberator_heartbeat" "\"role\":\"deliberator\""
    # scanner-anchor: "kind":"deliberator_heartbeat"
    echo "[deliberator] heartbeat emitted at $(_now_iso) for session $SESSION_ID"
    return 0
}

_cmd_help() {
    sed -n '1,/^set -euo pipefail$/p' "$0" | grep '^#' | sed 's/^# //; s/^#$//'
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

cmd="${1:-help}"
[[ $# -gt 0 ]] && shift || true

case "$cmd" in
    tick)       _cmd_tick "$@" ;;
    audit)      _cmd_audit "$@" ;;
    heartbeat)  _cmd_heartbeat "$@" ;;
    help|-h|--help) _cmd_help; exit 0 ;;
    *)
        echo "[deliberator] unknown subcommand: $cmd" >&2
        echo "Run '$0 help' for usage." >&2
        exit 2
        ;;
esac
