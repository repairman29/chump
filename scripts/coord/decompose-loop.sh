#!/usr/bin/env bash
# scripts/coord/decompose-loop.sh — INFRA-1924 (curator-opus-decompose).
#
# Harness-neutral CLI for the decompose curator role. Any harness (Claude
# Code, opencode-bigpickle, codex, manual operator) invokes it the same way.
# The .claude/ agent + skill wrappers delegate here; they are convenience,
# not capability — per .claude/README.md non-negotiable pattern.
#
# AC source: INFERRED from `chump gap decompose` CLI semantics + CLAUDE.md
# two-phase decomposition discipline + the role's session-name implying
# gap-slicing duty. Tracked in docs/process/CURATOR_ROLE_PRODUCTIZATION_AC_2026-05-24.md.
# Confirm-or-refactor when curator-opus-decompose session wakes up.
#
# Rust-First-Bypass: glue between `chump gap` + `gh` + jq, ~200 LOC, read-mostly
# (only writes are via `chump gap reserve` which is the canonical mutator).
# Mutating state lives in `chump gap …`; this script orchestrates calls.
#
# Usage:
#   scripts/coord/decompose-loop.sh <subcommand> [args]
#
# Subcommands:
#   slice <UMBRELLA-ID>    Read umbrella description + AC; call `chump gap
#                          decompose` to propose slices; review; reserve each
#                          accepted slice as a sub-gap; emit kind=decompose_sliced.
#                          Flags: --dry-run (print prompt only, no reserves)
#                                 --auto-accept (skip interactive review — for cron)
#                                 --max-slices N (cap proposed slices; default 5)
#   audit-pending          Scan open umbrella gaps (any with "Rough shape:" or
#                          "decompose at claim time" phrasing per CLAUDE.md
#                          doctrine) open >7d without sub-gaps; print candidates.
#                          Pairs with META-046 PM-curation.
#                          Exit 0 if zero candidates (stop condition).
#   heartbeat              Emit kind=decompose_heartbeat to ambient.jsonl
#                          + broadcast to orchestrator. Cron entry point.
#   help                   Print this.
#
# Exit codes:
#   0 — success (or zero candidates for audit-pending → stop condition)
#   1 — missing required arg / gap not found
#   2 — bad subcommand
#   3 — chump CLI unreachable / state.db inaccessible
#
# Cron: scripts/launchd/com.chump.decompose-loop.plist (every 30 min, runs `audit-pending`).
#
# Inbox protocol (AC#4): curator-opus-target can send kind=decompose_request
# with {gap_id, rationale}; decompose responds with kind=decompose_complete
# carrying child IDs. See docs/process/OPUS_MESSAGE_PROTOCOL.md.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="${CHUMP_LOCK_DIR:-$MAIN_REPO/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
SESSION_ID="${CHUMP_SESSION_ID:-decompose-loop-$$}"

cmd=${1:-help}
[ $# -gt 0 ] && shift || true

# ── helpers ────────────────────────────────────────────────────────────────

require_chump() {
    if ! command -v chump >/dev/null 2>&1; then
        echo "decompose-loop: chump CLI not on PATH" >&2
        exit 3
    fi
}

emit_ambient() {
    # emit_ambient <kind> <json-body-without-leading-brace>
    local kind="$1"
    local body="${2:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$AMBIENT_LOG")"
    if [[ -n "$body" ]]; then
        printf '{"ts":"%s","session":"%s","kind":"%s",%s}\n' \
            "$ts" "$SESSION_ID" "$kind" "$body" >> "$AMBIENT_LOG"
    else
        printf '{"ts":"%s","session":"%s","kind":"%s"}\n' \
            "$ts" "$SESSION_ID" "$kind" >> "$AMBIENT_LOG"
    fi
}

# ── Phase 0 helpers (META-160 / CHUMP_FLEET_RECV_SIDE_V0) ─────────────────

# Read inbox items for this session, advance cursor, print count to stdout.
# Mirrors ci-audit-loop.sh _peek_inbox pattern but also advances cursor.
# Returns: prints each inbox line; echoes count as last line prefixed "INBOX_COUNT="
_drain_inbox() {
    local inbox_file="$LOCK_DIR/inbox/${SESSION_ID}.jsonl"
    local cursor_file="$LOCK_DIR/inbox/${SESSION_ID}.cursor"
    if [[ ! -f "$inbox_file" ]]; then
        echo "INBOX_COUNT=0"
        return 0
    fi
    local offset=0
    if [[ -f "$cursor_file" ]]; then
        offset="$(cat "$cursor_file" 2>/dev/null || echo 0)"
        # Ensure offset is a non-negative integer
        [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
    fi
    local total_lines
    total_lines="$(wc -l < "$inbox_file" 2>/dev/null | tr -d ' ' || echo 0)"
    local new_count=$(( total_lines - offset ))
    if [[ "$new_count" -le 0 ]]; then
        echo "INBOX_COUNT=0"
        return 0
    fi
    tail -n +"$(( offset + 1 ))" "$inbox_file" 2>/dev/null || true
    # Advance cursor
    printf '%d\n' "$total_lines" > "$cursor_file"
    echo "INBOX_COUNT=$new_count"
}

# Scan last 200 lines of ambient log for unresolved FEEDBACK/proposal events.
# An event is "unresolved" if its corr_id does not appear in any
# kind=consensus_result event in the same 200-line window.
# Prints matching corr_ids (one per line); returns 0 if any found, 1 if none.
_peek_pending_feedback() {
    if [[ ! -f "$AMBIENT_LOG" ]]; then
        return 1
    fi
    local window
    window="$(tail -200 "$AMBIENT_LOG" 2>/dev/null || true)"
    if [[ -z "$window" ]]; then
        return 1
    fi
    # Extract corr_ids from FEEDBACK+proposal events
    local feedback_ids
    feedback_ids="$(printf '%s\n' "$window" \
        | grep '"event":"FEEDBACK"' \
        | grep '"kind":"proposal"' \
        | grep -o '"corr_id":"[^"]*"' \
        | sed 's/"corr_id":"//;s/"//' \
        || true)"
    if [[ -z "$feedback_ids" ]]; then
        return 1
    fi
    # Extract corr_ids from consensus_result events in same window
    local resolved_ids
    resolved_ids="$(printf '%s\n' "$window" \
        | grep '"kind":"consensus_result"' \
        | grep -o '"corr_id":"[^"]*"' \
        | sed 's/"corr_id":"//;s/"//' \
        || true)"
    # Print only unresolved feedback corr_ids
    local found=0
    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        if ! printf '%s\n' "$resolved_ids" | grep -qxF "$cid" 2>/dev/null; then  # pipefail-sweep-allowed
            printf '%s\n' "$cid"
            found=1
        fi
    done <<< "$feedback_ids"
    [[ "$found" -eq 1 ]] && return 0 || return 1
}

# ── slice ──────────────────────────────────────────────────────────────────
# scanner-anchor: "kind":"decompose_sliced"

cmd_slice() {
    require_chump
    local gap_id=""
    local dry_run=0
    local auto_accept=0
    local max_slices=5
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)     dry_run=1 ;;
            --auto-accept) auto_accept=1 ;;
            --max-slices)  shift; max_slices="${1:-5}" ;;
            -h|--help)     grep '^#' "$0" | sed -n '/^# Usage:/,/^# Cron:/p'; return 0 ;;
            *)             [[ -z "$gap_id" ]] && gap_id="$1" ;;
        esac
        shift || true
    done

    if [[ -z "$gap_id" ]]; then
        echo "decompose-loop slice: UMBRELLA-ID required" >&2
        return 1
    fi

    # Verify the umbrella exists and is open
    if ! chump gap show "$gap_id" >/dev/null 2>&1; then
        echo "decompose-loop slice: gap $gap_id not found" >&2
        return 1
    fi

    echo "decompose-loop: slicing $gap_id (max=$max_slices, dry_run=$dry_run, auto_accept=$auto_accept)"

    # Phase 1: dry-run shows the prompt; useful for review before LLM call
    if [[ "$dry_run" == "1" ]]; then
        chump gap decompose "$gap_id" --dry-run
        emit_ambient "decompose_sliced" \
            "\"parent_id\":\"$gap_id\",\"slice_count\":0,\"mode\":\"dry-run\""
        return 0
    fi

    # Phase 2: get JSON proposal from chump gap decompose
    local proposal_json
    if ! proposal_json="$(chump gap decompose "$gap_id" --json 2>/dev/null)"; then
        echo "decompose-loop slice: chump gap decompose --json failed for $gap_id" >&2
        return 1
    fi

    local proposed_count
    proposed_count="$(printf '%s' "$proposal_json" \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('slices', d.get('proposed_slices', []))))" \
        2>/dev/null || echo 0)"

    echo "decompose-loop: $proposed_count slice(s) proposed for $gap_id"

    if [[ "$proposed_count" == "0" ]]; then
        emit_ambient "decompose_sliced" \
            "\"parent_id\":\"$gap_id\",\"slice_count\":0,\"mode\":\"no-proposal\""
        return 0
    fi

    # Phase 3: accept (cron path = --auto-accept --apply; operator path = interactive)
    local child_ids="[]"
    if [[ "$auto_accept" == "1" ]]; then
        # Use --apply which both files the slices and demotes the parent.
        if chump gap decompose "$gap_id" --apply >/dev/null 2>&1; then
            child_ids="$(printf '%s' "$proposal_json" \
                | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps([s.get('id','') for s in d.get('slices', d.get('proposed_slices', []))]))" \
                2>/dev/null || echo '[]')"
        fi
    else
        echo "decompose-loop: review proposal below, then re-run with --auto-accept to apply"
        printf '%s\n' "$proposal_json"
    fi

    local capped="$proposed_count"
    if [[ "$proposed_count" -gt "$max_slices" ]]; then
        capped="$max_slices"
    fi

    emit_ambient "decompose_sliced" \
        "\"parent_id\":\"$gap_id\",\"slice_count\":$capped,\"child_ids\":$child_ids,\"llm_cost_usd\":null"

    return 0
}

# ── audit-pending ──────────────────────────────────────────────────────────
# scanner-anchor: "kind":"decompose_audit"

cmd_audit_pending() {
    require_chump

    local json_out=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json_out=1 ;;
            -h|--help) grep '^#' "$0" | sed -n '/^# Usage:/,/^# Cron:/p'; return 0 ;;
            *) ;;
        esac
        shift || true
    done

    # Walk open gaps. For each, check title+description for "Rough shape:" /
    # "decompose at claim time" doctrine markers + 7d age threshold.
    # Doctrine phrasing per CLAUDE.md two-phase decomposition section.
    local candidates_json
    local audit_py
    audit_py="$(cat <<'PYEOF'
import json, sys, datetime
try:
    gaps = json.load(sys.stdin)
except Exception:
    print('[]')
    sys.exit(0)
now = datetime.datetime.now(datetime.timezone.utc)
seven_d = datetime.timedelta(days=7)
candidates = []
DOCTRINE_PHRASES = [
    'rough shape:',
    'decompose at claim time',
    'sub-slice',
    'umbrella',
    'phase-n addendum',
]
for g in gaps:
    title = (g.get('title') or '').lower()
    desc = (g.get('description') or '').lower()
    haystack = title + '\n' + desc
    if not any(phrase in haystack for phrase in DOCTRINE_PHRASES):
        continue
    created = g.get('created_at') or g.get('created')
    if created:
        try:
            ts = datetime.datetime.fromisoformat(created.replace('Z', '+00:00'))
            if now - ts < seven_d:
                continue
        except Exception:
            pass
    candidates.append({
        'id': g.get('id'),
        'title': g.get('title'),
        'priority': g.get('priority'),
        'effort': g.get('effort'),
        'created_at': created,
    })
print(json.dumps(candidates, indent=2))
PYEOF
)"
    candidates_json="$(chump gap list --status open --json 2>/dev/null \
        | python3 -c "$audit_py")"

    local cand_count
    cand_count="$(printf '%s' "$candidates_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)"

    emit_ambient "decompose_audit" \
        "\"candidate_count\":$cand_count"

    if [[ "$json_out" == "1" ]]; then
        printf '%s\n' "$candidates_json"
    else
        echo "decompose-loop audit-pending: $cand_count umbrella candidates (open >7d with doctrine markers)"
        if [[ "$cand_count" -gt 0 ]]; then
            local print_py
            print_py='import json,sys
for g in json.load(sys.stdin):
    print("  - {:14s} {:3s} {}".format(g.get("id",""), g.get("priority","?"), (g.get("title","") or "")[:80]))'
            printf '%s\n' "$candidates_json" | python3 -c "$print_py" 2>/dev/null || true
        fi
    fi

    # Stop condition: zero candidates → exit 0 cleanly so cron doesn't spin
    return 0
}

# ── heartbeat ──────────────────────────────────────────────────────────────
# scanner-anchor: "kind":"decompose_heartbeat"

cmd_heartbeat() {
    emit_ambient "decompose_heartbeat" "\"role\":\"curator-opus-decompose\""

    # Optional broadcast — non-fatal if broadcast.sh unavailable
    if [[ -x "$MAIN_REPO/scripts/coord/broadcast.sh" ]] \
       && [[ "${CHUMP_DECOMPOSE_NO_BROADCAST:-0}" != "1" ]]; then
        local today
        today="$(date -u +%Y-%m-%d)"
        "$MAIN_REPO/scripts/coord/broadcast.sh" \
            --to "orchestrator-opus-$today" \
            INFO "decompose-loop heartbeat" >/dev/null 2>&1 || true
    fi
    echo "decompose-loop: heartbeat emitted"
    return 0
}

# ── tick (META-160: Phase 0 + existing decompose-queue scan) ──────────────

cmd_tick() {
    local actionable=0
    echo "=== decompose-loop tick @ $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    echo

    # Phase 0 (META-160): inbox drain + pending feedback peek.
    # Gated behind CHUMP_FLEET_RECV_SIDE_V0=1 — skipped when unset.
    if [[ "${CHUMP_FLEET_RECV_SIDE_V0:-0}" == "1" ]]; then
        echo "## Phase 0: inbox drain + pending FEEDBACK (CHUMP_FLEET_RECV_SIDE_V0)"

        # Drain inbox
        mkdir -p "$LOCK_DIR/inbox"
        local inbox_out
        inbox_out="$(_drain_inbox)"
        local inbox_count=0
        # Last line is "INBOX_COUNT=N"; preceding lines are inbox entries
        local inbox_entries
        inbox_entries="$(printf '%s\n' "$inbox_out" | grep -v '^INBOX_COUNT=' || true)"
        local count_line
        count_line="$(printf '%s\n' "$inbox_out" | grep '^INBOX_COUNT=' | tail -1 || true)"
        inbox_count="${count_line#INBOX_COUNT=}"
        inbox_count="${inbox_count:-0}"

        if [[ "$inbox_count" -gt 0 ]]; then
            echo "  [inbox] $inbox_count new message(s):"
            printf '%s\n' "$inbox_entries"
            actionable=1
        else
            echo "  [inbox] no new messages"
        fi

        # Peek pending feedback
        local feedback_ids
        feedback_ids="$(_peek_pending_feedback || true)"
        if [[ -n "$feedback_ids" ]]; then
            echo
            echo "## Pending FEEDBACK requiring vote"
            printf '%s\n' "$feedback_ids"
            actionable=1
        fi
        echo
    fi

    # Phase 1: existing decompose-queue scan (delegates to cmd_audit_pending)
    echo "## Phase 1: decompose-queue scan"
    cmd_audit_pending "$@" || true
    echo

    if (( actionable > 0 )); then
        echo "[decompose-loop] tick: actionable items found"
        return 0
    fi
    echo "[decompose-loop] tick: quiet — no actionable inbox or feedback items"
    return 1
}

# ── dispatcher ─────────────────────────────────────────────────────────────

case "$cmd" in
    slice)          cmd_slice "$@" ;;
    audit-pending)  cmd_audit_pending "$@" ;;
    heartbeat)      cmd_heartbeat "$@" ;;
    tick)
        # INFRA-2262: read fleet wire before doing tick work.
        "$(dirname "$0")/ambient-context-inject.sh" --tick-preamble decompose 2>/dev/null || true
        cmd_tick "$@"
        ;;
    help|-h|--help) grep '^#' "$0" | sed -n '3,55p' | sed 's/^# \{0,1\}//' ;;
    *)
        echo "decompose-loop: unknown subcommand $cmd (try: decompose-loop.sh help)" >&2
        exit 2
        ;;
esac
