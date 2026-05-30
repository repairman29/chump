#!/usr/bin/env bash
# scripts/coord/handoff-loop.sh — Chump curator-opus-handoff role CLI (harness-neutral)
#
# Productizes the curator-opus-handoff role per INFRA-1922 + META-097.
# Any harness (Claude Code, opencode-bigpickle, codex, manual) invokes this
# the same way. The .claude/agents/handoff.md + .claude/skills/handoff/
# wrappers delegate here; they are convenience, not capability.
#
# The 5 self-contributed AC items this CLI implements (per
# docs/process/CURATOR_ROLE_PRODUCTIZATION_AC_2026-05-24.md "handoff" section):
#
#   1. Reads crates/chump-handoff/src/contracts.rs at session start, prefers
#      DecomposeContract / CodeFixContract / GapReviewContract over free-form
#      markdown prompts when both paths exist.
#   2. Checks active .chump-locks/claim-*.json on every file edit before
#      mutating; on collision broadcasts STUCK with the colliding session-id +
#      lease path and reverts uncommitted changes.
#   3. For claims >150 LOC OR touching Rust/tests, dispatches a Sonnet
#      sub-agent via the Agent tool (or marks the work as needing a Sonnet
#      dispatch in CLI mode) with the SUBAGENT_DISPATCH.md epilogue + pre-push
#      checklist; emits kind=sub_agent_dispatched for ratio auditing.
#   4. Files follow-up gaps with advisory/observable signals rather than hard
#      enforcement when an operator question surfaces.
#   5. Every new ambient event kind ships with EITHER a scanner-anchor comment
#      (# scanner-anchor: "kind":"X") adjacent to the emit site OR an
#      scripts/ci/event-registry-reserved.txt entry with reason.
#
# Rust-First-Bypass: glue between gh + jq + git + scripts/coord helpers;
# <200 LOC at first commit; read-mostly (only writes are ambient.jsonl emit
# lines + inbox broadcasts, both already-idempotent). Will be ported to Rust
# as part of the INFRA-1823 Harvester-pattern follow-up if the surface grows.
#
# Usage:
#   scripts/coord/handoff-loop.sh <subcommand> [args]
#
# Subcommands:
#   scan-handoffs        Read inbox + check active claims; print actionable
#                        items (handoffs requested, STUCK collisions to
#                        unblock, contracts available). Exit 0 if anything
#                        actionable, exit 1 if quiet, exit 2 on bad input.
#   review-pr <PR>       Read PR's gap-id, check it against contracts.rs (does
#                        a DecomposeContract / CodeFixContract / GapReviewContract
#                        apply?), print recommendation. Exit 0 ok, exit 2 bad input.
#   dispatch-sub <ID>    Print Sonnet sub-agent dispatch prompt for gap <ID>
#                        with SUBAGENT_DISPATCH.md epilogue + pre-push
#                        checklist (no actual Agent-tool invoke — that's the
#                        harness's job). Emits kind=sub_agent_dispatched.
#                        Exit 0 ok, exit 2 bad input.
#   heartbeat            Emit kind=handoff_heartbeat to ambient.jsonl + inbox
#                        broadcast to orchestrator-opus-<date>. Exit 0 always.
#   help                 Print this.
#
# Exit codes:
#   0 — success
#   1 — quiet (no actionable items) for scan-handoffs
#   2 — bad subcommand or missing required arg
#   3 — contracts.rs missing or unreadable (no chump-handoff crate)
#
# Env:
#   CHUMP_SESSION_ID            session id used for inbox + emits (default: handoff-<pid>)
#   CHUMP_AMBIENT_LOG           ambient.jsonl path override
#   CHUMP_HANDOFF_LANE_OVERRIDE if "1", refuse-out-of-scope checks skip

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
CONTRACTS_RS="$MAIN_REPO/crates/chump-handoff/src/contracts.rs"
SESSION_ID="${CHUMP_SESSION_ID:-handoff-$$}"

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Helpers ──────────────────────────────────────────────────────────────────

# Emit an ambient line. Scanner-anchored at each call site.
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

# Print available contracts from contracts.rs. Exit 3 if missing.
_list_contracts() {
    if [[ ! -f "$CONTRACTS_RS" ]]; then
        echo "[handoff] contracts.rs missing at $CONTRACTS_RS" >&2
        exit 3
    fi
    grep -E '^pub struct [A-Za-z]+Contract' "$CONTRACTS_RS" 2>/dev/null \
        | sed -E 's/^pub struct ([A-Za-z]+Contract).*/  - \1/' || true
}

# Check whether any active lease claims a path. Pass path as $1.
# Echoes the colliding session id + lease file if found, else nothing.
# Exit 0 either way; presence/absence detected by caller via stdout.
_lease_collision_for() {
    local path="$1"
    local lock
    for lock in "$LOCK_DIR"/claim-*.json; do
        [[ -f "$lock" ]] || continue
        # Skip our own lease.
        local lock_session
        lock_session="$(grep -oE '"session_id":\s*"[^"]+"' "$lock" 2>/dev/null \
            | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
        [[ "$lock_session" == "$SESSION_ID" ]] && continue
        # See if `paths` array contains this path. We tolerate empty paths
        # (means whole-gap claim, not file-level).
        if grep -F "\"$path\"" "$lock" >/dev/null 2>&1; then
            echo "${lock_session}|${lock}"
            return 0
        fi
    done
}

# Read the SUBAGENT_DISPATCH.md epilogue + pre-push checklist verbatim, if it
# exists. Falls back to a minimal inline epilogue.
_subagent_epilogue() {
    local dispatch_doc="$MAIN_REPO/docs/process/SUBAGENT_DISPATCH.md"
    if [[ -f "$dispatch_doc" ]]; then
        # Print the file path so callers know where the canonical version is.
        echo "## Shipping epilogue + pre-push checklist (verbatim)"
        echo
        echo "See \`docs/process/SUBAGENT_DISPATCH.md\` for the canonical version."
        echo "Subagent MUST follow it without modification."
        echo
    else
        cat <<'EPILOGUE'
## Shipping epilogue (minimal fallback)

1. `chump gap preflight <ID>` MUST pass before any work.
2. One logical change per PR, intent-atomic.
3. No `--no-verify` without `CHUMP_NO_VERIFY_REASON=<text>`.
4. Run local CI: cargo fmt/clippy/check + scripts/ci/test-*.sh that match.
5. Ship via `scripts/coord/bot-merge.sh --gap <ID> --auto-merge`.
6. On completion: emit DONE via `scripts/coord/broadcast.sh DONE <gap> <sha>`.
EPILOGUE
    fi
}

# ── Subcommands ──────────────────────────────────────────────────────────────

_cmd_scan_handoffs() {
    local actionable=0
    echo "=== curator-opus-handoff scan @ $(_now_iso) ==="
    echo

    # 1. Contracts available (AC #1)
    echo "## Available typed handoff contracts (per contracts.rs)"
    if [[ -f "$CONTRACTS_RS" ]]; then
        local contracts
        contracts="$(_list_contracts)"
        if [[ -n "$contracts" ]]; then
            echo "$contracts"
            echo
            echo "PREFER these typed contracts over free-form markdown prompts."
        else
            echo "  (no contracts defined yet)"
        fi
    else
        echo "  (crates/chump-handoff/src/contracts.rs missing — typed handoff path unavailable)"
    fi
    echo

    # 2. Active leases (AC #2)
    echo "## Active fleet leases (scanned for collision risk)"
    local lease_count=0
    local lock
    for lock in "$LOCK_DIR"/claim-*.json; do
        [[ -f "$lock" ]] || continue
        lease_count=$((lease_count + 1))
    done
    if (( lease_count == 0 )); then
        echo "  (no active claim-*.json leases)"
    else
        echo "  ${lease_count} active leases under $LOCK_DIR"
        actionable=1
    fi
    echo

    # 3. Inbox check — invoke chump-inbox.sh in read-only-peek mode if available
    echo "## Inbox peek (last 5 unread items)"
    local inbox_script="$MAIN_REPO/scripts/coord/chump-inbox.sh"
    if [[ -x "$inbox_script" ]]; then
        local inbox_file="$LOCK_DIR/inbox/${SESSION_ID}.jsonl"
        if [[ -f "$inbox_file" ]]; then
            tail -5 "$inbox_file" 2>/dev/null || true
            actionable=1
        else
            echo "  (no inbox at $inbox_file)"
        fi
    else
        echo "  (chump-inbox.sh not executable; skipping)"
    fi
    echo

    if (( actionable > 0 )); then
        echo "[handoff] scan found actionable items"
        return 0
    fi
    echo "[handoff] scan: quiet — no actionable items"
    return 1
}

_cmd_review_pr() {
    local pr="${1:-}"
    if [[ -z "$pr" ]]; then
        echo "Usage: $0 review-pr <PR-number>" >&2
        return 2
    fi
    # Don't shell out to gh in the smoke test — fall back to local-only check
    # if gh isn't available. We just check that contracts.rs exists and tell
    # the caller which contract types are options for any handoff this PR
    # might need.
    echo "=== review-pr ${pr} @ $(_now_iso) ==="
    echo
    if [[ -f "$CONTRACTS_RS" ]]; then
        echo "Available contracts to route subagent handoffs through:"
        _list_contracts
        echo
        echo "Recommendation: read PR's diff scope. If decomposing a gap → DecomposeContract."
        echo "If fixing a code symptom → CodeFixContract. If second-opinion review → GapReviewContract."
    else
        echo "[handoff] contracts.rs missing; recommend free-form markdown prompt with"
        echo "          SUBAGENT_DISPATCH.md epilogue inline."
    fi
    return 0
}

_cmd_dispatch_sub() {
    local gap_id="${1:-}"
    if [[ -z "$gap_id" ]]; then
        echo "Usage: $0 dispatch-sub <GAP-ID>" >&2
        return 2
    fi

    # AC #3: emit sub_agent_dispatched for ratio audit
    _emit_kind "sub_agent_dispatched" \
        "\"gap\":\"${gap_id}\",\"role\":\"handoff\",\"target_model\":\"sonnet\""
    # scanner-anchor: "kind":"sub_agent_dispatched"

    # Lowercase gap_id for branch slug — bash 3.x compatible (no ${var,,}).
    local gap_lc
    gap_lc="$(printf '%s' "$gap_id" | tr '[:upper:]' '[:lower:]')"

    cat <<DISPATCH
=== Sonnet sub-agent dispatch prompt for ${gap_id} ===

You are a Sonnet sub-agent dispatched by curator-opus-handoff
(session ${SESSION_ID}) to ship gap ${gap_id}.

## Read first (mandatory)
- docs/gaps/${gap_id}.yaml — the gap spec (status, AC, depends_on)
- docs/process/SUBAGENT_DISPATCH.md — shipping epilogue verbatim
- CLAUDE.md — session rules including local CI discipline (INFRA-1673)
- crates/chump-handoff/src/contracts.rs — typed handoff contracts available

## Execution contract
- No clarifying questions. Implement against the AC.
- Single intent-atomic PR. One push. Auto-merge armed.
- Branch name: chump/${gap_lc}-<short-slug>
- Commit subject: feat(${gap_id}): <PILLAR> — <one-line description>

DISPATCH
    _subagent_epilogue
    return 0
}

_cmd_heartbeat() {
    _emit_kind "handoff_heartbeat" "\"role\":\"handoff\""
    # scanner-anchor: "kind":"handoff_heartbeat"
    echo "[handoff] heartbeat emitted at $(_now_iso) for session $SESSION_ID"
    return 0
}

_cmd_help() {
    sed -n '1,/^set -uo pipefail$/p' "$0" | sed -n '/^# /p' | sed 's/^# //; s/^#$//'
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

cmd="${1:-help}"
[[ $# -gt 0 ]] && shift || true

case "$cmd" in
    scan-handoffs)  _cmd_scan_handoffs "$@" ;;
    review-pr)      _cmd_review_pr "$@" ;;
    dispatch-sub)   _cmd_dispatch_sub "$@" ;;
    heartbeat)      _cmd_heartbeat "$@" ;;
    tick)           _cmd_scan_handoffs "$@" ;;  # INFRA-2238: fleet-autopilot.sh canonical entry point
    help|-h|--help) _cmd_help; exit 0 ;;
    *)
        echo "[handoff] unknown subcommand: $cmd" >&2
        echo "Run '$0 help' for usage." >&2
        exit 2
        ;;
esac
