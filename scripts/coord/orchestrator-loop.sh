#!/usr/bin/env bash
# scripts/coord/orchestrator-loop.sh — Chump orchestrator-opus (wizard) role CLI (harness-neutral)
#
# Productizes the orchestrator/wizard role per INFRA-1917 + META-097, mirroring
# the ci-audit-loop.sh / decompose-loop.sh / handoff-loop.sh / md-links-loop.sh /
# shepherd-loop.sh / target-loop.sh pattern. Any harness (Claude Code,
# opencode-bigpickle, codex, manual) invokes this the same way. The
# .claude/agents/orchestrator.md + .claude/skills/orchestrator/ wrappers
# delegate here; they are convenience, not capability.
#
# This role drives the pulse-and-dispatch cycle: read inbox, pulse the PR
# queue, rank gaps against docs/ROADMAP.md, and send directed dispatches to
# curator-opus-* sessions. It does NOT do lane-curator work itself (target /
# handoff / ci-audit / shepherd / decompose / md-links own their PRs).
#
# Rust-First-Bypass: thin dispatcher over three existing, already-shipped
# capability scripts (pr-pulse.sh, chump-inbox.sh, role-card-emit.sh); no new
# state mutation logic lives here — <100 LOC glue.
#
# Usage:
#   scripts/coord/orchestrator-loop.sh <subcommand> [args]
#
# Subcommands:
#   tick          One full pulse-and-dispatch cycle: read inbox cursor, pulse
#                 the PR queue (WEDGED/SATURATED/HEALTHY verdict), print
#                 roadmap-alignment summary. Exit 0 if actionable (non-HEALTHY
#                 or inbox items pending), exit 1 if quiet/HEALTHY.
#   pulse         PR-queue pulse only — delegates to pr-pulse.sh.
#   inbox         Inbox triage only — delegates to chump-inbox.sh read.
#   role-card     Emit a role-card so peers can dedupe this session —
#                 delegates to role-card-emit.sh --role orchestrator-opus.
#   heartbeat     Emit kind=orchestrator_heartbeat to ambient.jsonl. Exit 0 always.
#   help          Print this.
#
# Exit codes:
#   0 — success / actionable items found
#   1 — quiet (queue HEALTHY, no inbox items)
#   2 — bad subcommand
#
# Env:
#   CHUMP_SESSION_ID   session id for inbox + emits (default: orchestrator-<pid>)
#   CHUMP_AMBIENT_LOG  ambient.jsonl path override

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="$REPO_ROOT/.chump-locks"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
export CHUMP_SESSION_ID="${CHUMP_SESSION_ID:-orchestrator-$$}"

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_cmd_heartbeat() {
    mkdir -p "$LOCK_DIR" 2>/dev/null || true
    printf '{"ts":"%s","kind":"orchestrator_heartbeat","session":"%s","role":"orchestrator"}\n' \
        "$(_now_iso)" "$CHUMP_SESSION_ID" >> "$AMBIENT" 2>/dev/null || true
    # scanner-anchor: "kind":"orchestrator_heartbeat"
    echo "[orchestrator] heartbeat emitted at $(_now_iso) for session $CHUMP_SESSION_ID"
    return 0
}

_cmd_pulse() {
    bash "$SCRIPT_DIR/pr-pulse.sh" "$@"
}

_cmd_inbox() {
    bash "$SCRIPT_DIR/chump-inbox.sh" read --no-advance
}

_cmd_role_card() {
    bash "$SCRIPT_DIR/role-card-emit.sh" --role orchestrator-opus --lane MISSION --wake-mode event-driven "$@"
}

_cmd_tick() {
    echo "=== curator-opus-orchestrator (wizard) tick @ $(_now_iso) ==="
    echo
    echo "## Phase 1: inbox triage"
    local inbox_out
    inbox_out="$(bash "$SCRIPT_DIR/chump-inbox.sh" read --no-advance 2>&1 || true)"
    printf '%s\n' "$inbox_out"
    local actionable=0
    if [[ -n "$inbox_out" && "$inbox_out" != *"no messages"* && "$inbox_out" != *"(empty)"* ]]; then
        actionable=1
    fi
    echo
    echo "## Phase 2: PR-queue pulse"
    local pulse_rc=0
    local pulse_out
    pulse_out="$(bash "$SCRIPT_DIR/pr-pulse.sh" 2>&1)" || pulse_rc=$?
    printf '%s\n' "$pulse_out"
    if [[ "$pulse_out" == *"WEDGED"* || "$pulse_out" == *"SATURATED"* ]]; then
        actionable=1
    fi
    echo
    echo "## Phase 3: roadmap check (top of docs/ROADMAP.md)"
    if [[ -f "$REPO_ROOT/docs/ROADMAP.md" ]]; then
        head -20 "$REPO_ROOT/docs/ROADMAP.md"
    else
        echo "  (docs/ROADMAP.md not found)"
    fi
    echo

    if (( actionable > 0 )); then
        echo "[orchestrator] tick: actionable — inbox items or non-HEALTHY queue"
        return 0
    fi
    echo "[orchestrator] tick: quiet — queue HEALTHY, inbox empty"
    return 1
}

_cmd_help() {
    sed -n '1,/^set -euo pipefail$/p' "$0" | grep '^#' | sed 's/^# //; s/^#$//'
}

cmd="${1:-help}"
[[ $# -gt 0 ]] && shift || true

case "$cmd" in
    tick)       _cmd_tick "$@" ;;
    pulse)      _cmd_pulse "$@" ;;
    inbox)      _cmd_inbox "$@" ;;
    role-card)  _cmd_role_card "$@" ;;
    heartbeat)  _cmd_heartbeat "$@" ;;
    help|-h|--help) _cmd_help; exit 0 ;;
    *)
        echo "[orchestrator] unknown subcommand: $cmd" >&2
        echo "Run '$0 help' for usage." >&2
        exit 2
        ;;
esac
