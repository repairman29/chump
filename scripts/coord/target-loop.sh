#!/usr/bin/env bash
# scripts/coord/target-loop.sh — Chump curator-opus-target role CLI (harness-neutral)
#
# Productizes the curator-opus-target role per INFRA-1917 + META-097, mirroring
# the ci-audit-loop.sh / decompose-loop.sh / handoff-loop.sh / md-links-loop.sh /
# shepherd-loop.sh / orchestrator-loop.sh pattern. Any harness (Claude Code,
# opencode-bigpickle, codex, manual) invokes this the same way. The
# .claude/agents/target.md + .claude/skills/target/ wrappers delegate here;
# they are convenience, not capability.
#
# This role owns the demo-target + INFRA-1318 Liaison Phase 2 + META-074
# child A/B/C umbrella lane: advancing the active claim, picking next-best
# work in lane, dispatching N Sonnet subagents in parallel per META-069, and
# babysitting in-flight PRs that fail audit gates. It does NOT rescue PRs
# outside its three umbrellas (shepherd's lane) or do CI-gate decomposition
# (ci-audit's lane).
#
# Rust-First-Bypass: thin dispatcher glueing existing chump-inbox.sh /
# bot-merge.sh / broadcast.sh calls together; <150 LOC, no new state
# mutation logic — the actual advance/dispatch/rescue mechanics already
# live in those scripts.
#
# Usage:
#   scripts/coord/target-loop.sh <subcommand> [args]
#
# Subcommands:
#   tick               One full 5-step work-your-lane cycle: read inbox,
#                       report active-claim status, print lane scope.
#                       Exit 0 if actionable (inbox items or active claim),
#                       exit 1 if quiet.
#   status              Print lane scope + active claim (from .chump-locks
#                       lease files) + last DONE broadcasts.
#   dispatch <GAP-IDs>  Print the META-069 dispatch checklist for the given
#                       comma-separated gap IDs (actual Sonnet spawn happens
#                       via the Agent tool in the calling harness).
#   rescue <PR-N>       Print the babysit + surgical-rescue checklist for a
#                       specific PR number.
#   heartbeat           Emit kind=target_heartbeat to ambient.jsonl. Exit 0 always.
#   help                Print this.
#
# Exit codes:
#   0 — success / actionable items found
#   1 — quiet (no actionable items)
#   2 — bad subcommand or missing required arg
#
# Env:
#   CHUMP_SESSION_ID   session id for inbox + emits (default: target-<pid>)
#   CHUMP_AMBIENT_LOG  ambient.jsonl path override

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="$REPO_ROOT/.chump-locks"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
export CHUMP_SESSION_ID="${CHUMP_SESSION_ID:-target-$$}"

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_cmd_heartbeat() {
    mkdir -p "$LOCK_DIR" 2>/dev/null || true
    printf '{"ts":"%s","kind":"target_heartbeat","session":"%s","role":"target"}\n' \
        "$(_now_iso)" "$CHUMP_SESSION_ID" >> "$AMBIENT" 2>/dev/null || true
    # scanner-anchor: "kind":"target_heartbeat"
    echo "[target] heartbeat emitted at $(_now_iso) for session $CHUMP_SESSION_ID"
    return 0
}

_cmd_status() {
    echo "=== curator-opus-target status @ $(_now_iso) ==="
    echo
    echo "## Lane scope"
    echo "  1. Column-A demo target (docs/strategy/COLUMN_A_DEMO_TARGET_2026-05-23.md)"
    echo "  2. INFRA-1318 Liaison Phase 2 (docs/design/GITHUB_LIAISON.md)"
    echo "  3. META-074 children A/B/C (docs/strategy/ROLE_SCOPED_FLEET_2026-05-23.md)"
    echo
    echo "## Active leases held by this session"
    local found=0
    local lock
    for lock in "$LOCK_DIR"/claim-*.json; do
        [[ -f "$lock" ]] || continue
        if grep -q "\"session\":\"$CHUMP_SESSION_ID\"" "$lock" 2>/dev/null; then
            echo "  $lock"
            found=1
        fi
    done
    (( found == 0 )) && echo "  (none)"
    return 0
}

_cmd_dispatch() {
    local gap_ids="${1:-}"
    if [[ -z "$gap_ids" ]]; then
        echo "[target] dispatch requires a comma-separated GAP-ID list" >&2
        return 2
    fi
    echo "=== curator-opus-target dispatch checklist (META-069) ==="
    echo "Gaps: $gap_ids"
    echo
    echo "For each gap ID above, launch a Sonnet subagent via the Agent tool with:"
    echo "  - The full shipping epilogue from docs/process/SUBAGENT_DISPATCH.md"
    echo "  - The pre-push checklist from docs/process/SUBAGENT_DISPATCH.md"
    echo "  - Model: sonnet (INFRA-515 — never haiku, it hesitates on --dangerously-skip-permissions)"
    echo "Emit kind=sub_agent_dispatched per launch for the Opus-vs-Sonnet ratio audit."
    return 0
}

_cmd_rescue() {
    local pr="${1:-}"
    if [[ -z "$pr" ]]; then
        echo "[target] rescue requires a PR number" >&2
        return 2
    fi
    echo "=== curator-opus-target babysit + surgical-rescue (PR #$pr) ==="
    echo
    echo "1. Check status: gh pr view $pr --json statusCheckRollup,mergeStateStatus"
    echo "2. If mergeStateStatus=BEHIND: gh pr update-branch $pr"
    echo "3. If audit-gate cancel: retrigger via bot-merge.sh --gap <GAP-ID> --auto-merge"
    echo "4. If genuinely failing: surgical fix in-place, one commit, re-push"
    echo "5. On resolution: broadcast DONE to orchestrator-opus session"
    return 0
}

_cmd_tick() {
    echo "=== curator-opus-target tick @ $(_now_iso) ==="
    echo
    echo "## Phase 1: inbox"
    local inbox_out
    inbox_out="$(bash "$SCRIPT_DIR/chump-inbox.sh" read --no-advance 2>&1 || true)"
    printf '%s\n' "$inbox_out"
    local actionable=0
    if [[ -n "$inbox_out" && "$inbox_out" != *"no messages"* && "$inbox_out" != *"(empty)"* ]]; then
        actionable=1
    fi
    echo
    echo "## Phase 2: active claim + lane scope"
    _cmd_status
    if [[ -f "$LOCK_DIR/claim-${CHUMP_SESSION_ID}.json" ]]; then
        actionable=1
    fi
    echo

    if (( actionable > 0 )); then
        echo "[target] tick: actionable — inbox items or active claim present"
        return 0
    fi
    echo "[target] tick: quiet — no inbox items, no active claim"
    return 1
}

_cmd_help() {
    sed -n '1,/^set -euo pipefail$/p' "$0" | grep '^#' | sed 's/^# //; s/^#$//'
}

cmd="${1:-help}"
[[ $# -gt 0 ]] && shift || true

# INFRA-1798: mandatory Glance phase — drain + act on inbox before any work.
if [[ "$cmd" != "help" && "$cmd" != "-h" && "$cmd" != "--help" ]]; then
    source "$(dirname "$0")/lib/inbox-glance.sh" 2>/dev/null && chump_inbox_glance "target" || true
fi

case "$cmd" in
    tick)       _cmd_tick "$@" ;;
    status)     _cmd_status "$@" ;;
    dispatch)   _cmd_dispatch "$@" ;;
    rescue)     _cmd_rescue "$@" ;;
    heartbeat)  _cmd_heartbeat "$@" ;;
    help|-h|--help) _cmd_help; exit 0 ;;
    *)
        echo "[target] unknown subcommand: $cmd" >&2
        echo "Run '$0 help' for usage." >&2
        exit 2
        ;;
esac
