#!/usr/bin/env bash
# scripts/setup/agent-session-id.sh — INFRA-2024
#
# Generates and persists a STABLE, UNIQUE per-agent CHUMP_SESSION_ID so that
# each Claude Code session gets its own dedicated inbox slot instead of
# sharing the generic chump-Chump-<ts>.jsonl mailbag.
#
# Two intended call paths:
#
#   (a) Operator sources in each new Claude Code window:
#         source scripts/setup/agent-session-id.sh
#
#   (b) SessionStart hook in .claude/settings.json calls this script
#       (see scripts/setup/install-ambient-hooks.sh or add manually).
#
# Stability contract:
#   - If CHUMP_SESSION_ID is already set in env, use it unchanged (idempotent).
#   - Otherwise derive: "claude-<workdir-basename>-<pid>-<rand4>"
#     and persist to .chump-locks/session-<pid>.env so any tool in the same
#     session can reload it via:
#         source "$(git rev-parse --show-toplevel)/.chump-locks/session-$$.env"
#
# Uniqueness contract:
#   - PID distinguishes parallel agents on the same machine.
#   - rand4 (4 hex chars) provides collision resistance when PIDs wrap.
#
# Usage:
#   source scripts/setup/agent-session-id.sh          # sets CHUMP_SESSION_ID in calling shell
#   bash   scripts/setup/agent-session-id.sh          # prints the generated id (for hooks)
#   bash   scripts/setup/agent-session-id.sh --env    # prints KEY=VALUE for eval
#
# Exit codes: 0 always (best-effort; never blocks Claude Code startup).

set -euo pipefail

# Determine if we're being sourced or executed.
_AGENT_SESSION_SOURCED=0
if [[ "${BASH_SOURCE[0]:-}" != "${0:-}" ]]; then
    _AGENT_SESSION_SOURCED=1
fi

# ── Locate repo root ────────────────────────────────────────────────────────
_agentid_repo="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [[ -z "$_agentid_repo" ]]; then
    # Outside a git repo — synthesise a minimal id and bail cleanly.
    _derived_id="claude-unknown-$$-$(head -c 2 /dev/urandom 2>/dev/null | xxd -p 2>/dev/null | head -c 4 || echo "xxxx")"
    if [[ "$_AGENT_SESSION_SOURCED" == "1" ]]; then
        export CHUMP_SESSION_ID="${CHUMP_SESSION_ID:-$_derived_id}"
    else
        echo "${CHUMP_SESSION_ID:-$_derived_id}"
    fi
    exit 0
fi

_LOCKS="$_agentid_repo/.chump-locks"
mkdir -p "$_LOCKS"

# ── Path 1: already set in environment — use as-is ─────────────────────────
if [[ -n "${CHUMP_SESSION_ID:-}" ]]; then
    _final_id="$CHUMP_SESSION_ID"

# ── Path 2: persisted env file from a previous call in this process tree ───
elif [[ -f "$_LOCKS/session-$$.env" ]]; then
    # shellcheck source=/dev/null
    source "$_LOCKS/session-$$.env"
    _final_id="${CHUMP_SESSION_ID:-}"

# ── Path 3: generate fresh id ───────────────────────────────────────────────
else
    _wdir_base="$(basename "$_agentid_repo")"
    _rand4="$(head -c 2 /dev/urandom 2>/dev/null | xxd -p 2>/dev/null | head -c 4 || printf '%04x' $((RANDOM % 65536)))"
    _final_id="claude-${_wdir_base}-$$-${_rand4}"

    # Write a persistent env file so tool calls in the same Claude Code process
    # (which share PID) can reload it without regenerating.
    printf 'CHUMP_SESSION_ID=%s\n' "$_final_id" > "$_LOCKS/session-$$.env"
fi

# ── Export / print ──────────────────────────────────────────────────────────
if [[ "$_AGENT_SESSION_SOURCED" == "1" ]]; then
    export CHUMP_SESSION_ID="$_final_id"
else
    case "${1:-}" in
        --env)  printf 'CHUMP_SESSION_ID=%s\n' "$_final_id" ;;
        *)      printf '%s\n' "$_final_id" ;;
    esac
fi

# Cleanup: unset internal vars so they don't pollute the sourcing shell.
unset _agentid_repo _LOCKS _final_id _wdir_base _rand4 _AGENT_SESSION_SOURCED
