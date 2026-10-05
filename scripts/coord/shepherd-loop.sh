#!/usr/bin/env bash
# scripts/coord/shepherd-loop.sh — Chump curator-opus-shepherd role CLI (harness-neutral)
#
# Productizes the curator-opus-shepherd role per INFRA-1917 + META-097, mirroring
# the ci-audit-loop.sh / decompose-loop.sh / handoff-loop.sh / md-links-loop.sh /
# target-loop.sh pattern. Any harness (Claude Code, opencode-bigpickle, codex,
# manual) invokes this the same way. The .claude/agents/shepherd.md +
# .claude/skills/shepherd/ wrappers delegate here; they are convenience, not
# capability.
#
# This role owns general PR rescue: unwedging stuck PRs, rebasing BEHIND
# branches, re-arming auto-merge, and filing follow-up gaps for genuine
# CI failures found along the way. It does NOT duplicate the CI-gate
# decomposition (ci-audit's lane) or typed-handoff routing (handoff's lane).
#
# Rust-First-Bypass: thin dispatcher over two existing, already-shipped
# capability scripts (opus-shepherd-triage.sh, pr-shepherd-daemon.sh); no new
# state mutation logic lives here — <100 LOC glue.
#
# Usage:
#   scripts/coord/shepherd-loop.sh <subcommand> [args]
#
# Subcommands:
#   tick          One full work-your-lane cycle: session-start triage
#                 (ghost-gap sweep, ambient signature stats, sibling leases,
#                 pickable diff, game-plan) followed by one PR-rescue tick
#                 (classify + act on BEHIND/BLOCKED/ARMED PRs).
#                 Exit 0 if actionable, exit 1 if quiet.
#   audit         Session-start triage only (no PR-rescue actions taken) —
#                 delegates to opus-shepherd-triage.sh --json.
#   rescue        PR-rescue tick only (no triage) — delegates to
#                 pr-shepherd-daemon.sh tick.
#   heartbeat     Emit kind=shepherd_heartbeat to ambient.jsonl. Exit 0 always.
#   help          Print this.
#
# Exit codes:
#   0 — success / actionable items found
#   1 — quiet (no actionable items)
#   2 — bad subcommand
#
# Env:
#   CHUMP_SESSION_ID   session id for inbox + emits (default: shepherd-<pid>)
#   CHUMP_AMBIENT_LOG  ambient.jsonl path override

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="$REPO_ROOT/.chump-locks"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
export CHUMP_SESSION_ID="${CHUMP_SESSION_ID:-shepherd-$$}"

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_cmd_heartbeat() {
    mkdir -p "$LOCK_DIR" 2>/dev/null || true
    printf '{"ts":"%s","kind":"shepherd_heartbeat","session":"%s","role":"shepherd"}\n' \
        "$(_now_iso)" "$CHUMP_SESSION_ID" >> "$AMBIENT" 2>/dev/null || true
    # scanner-anchor: "kind":"shepherd_heartbeat"
    echo "[shepherd] heartbeat emitted at $(_now_iso) for session $CHUMP_SESSION_ID"
    return 0
}

_cmd_audit() {
    bash "$SCRIPT_DIR/opus-shepherd-triage.sh" --json
}

_cmd_rescue() {
    bash "$SCRIPT_DIR/pr-shepherd-daemon.sh" tick
}

_cmd_tick() {
    echo "=== curator-opus-shepherd tick @ $(_now_iso) ==="
    echo
    echo "## Phase 1: session-start triage"
    local triage_rc=0
    bash "$SCRIPT_DIR/opus-shepherd-triage.sh" tick || triage_rc=$?
    echo
    echo "## Phase 2: PR-rescue tick"
    local rescue_rc=0
    bash "$SCRIPT_DIR/pr-shepherd-daemon.sh" tick || rescue_rc=$?
    if (( triage_rc == 0 || rescue_rc == 0 )); then
        return 0
    fi

    # INFRA-2210: no-idle fallback before declaring quiet.
    # shellcheck source=/dev/null
    if source "$SCRIPT_DIR/lib/no-idle.sh" 2>/dev/null && no_idle_try_fallback "shepherd"; then
        echo "[shepherd] tick: no-op avoided — took fallback action instead of idling"
        return 0
    fi

    return 1
}

_cmd_help() {
    sed -n '1,/^set -euo pipefail$/p' "$0" | grep '^#' | sed 's/^# //; s/^#$//'
}

cmd="${1:-help}"
[[ $# -gt 0 ]] && shift || true

# INFRA-1798: mandatory Glance phase — drain + act on inbox before any work.
if [[ "$cmd" != "help" && "$cmd" != "-h" && "$cmd" != "--help" ]]; then
    source "$(dirname "$0")/lib/inbox-glance.sh" 2>/dev/null && chump_inbox_glance "shepherd" || true
fi

case "$cmd" in
    tick)       _cmd_tick "$@" ;;
    audit)      _cmd_audit "$@" ;;
    rescue)     _cmd_rescue "$@" ;;
    heartbeat)  _cmd_heartbeat "$@" ;;
    help|-h|--help) _cmd_help; exit 0 ;;
    *)
        echo "[shepherd] unknown subcommand: $cmd" >&2
        echo "Run '$0 help' for usage." >&2
        exit 2
        ;;
esac
