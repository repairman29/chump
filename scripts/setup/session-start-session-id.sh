#!/usr/bin/env bash
# scripts/setup/session-start-session-id.sh — INFRA-2024
#
# SessionStart hook: generates a stable per-agent CHUMP_SESSION_ID and writes
# it to .chump-locks/session-<pid>.env so that inbox-poll.sh (and any other
# fleet script that needs a session identity) can resolve it without falling
# through to the shared chump-Chump-<ts>.jsonl mailbag.
#
# Called by .claude/settings.json → hooks.SessionStart
# (command is run via bash, not sourced, so it cannot set env vars in the
# Claude Code process directly — it persists the id to a file instead, which
# inbox-poll.sh reads via its CHUMP_SESSION_ID derivation chain).
#
# Exit: always 0 (never blocks Claude Code startup).

set -euo pipefail

REPO="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
[[ -z "$REPO" ]] && exit 0

LOCKS="$REPO/.chump-locks"
mkdir -p "$LOCKS"

# Skip if already written for this PID (idempotent on re-run within same session)
ENV_FILE="$LOCKS/session-$$.env"
if [[ -f "$ENV_FILE" ]]; then
    exit 0
fi

# Honour an explicitly-set CHUMP_SESSION_ID (operator override)
if [[ -n "${CHUMP_SESSION_ID:-}" ]]; then
    printf 'CHUMP_SESSION_ID=%s\n' "$CHUMP_SESSION_ID" > "$ENV_FILE"
    exit 0
fi

# Generate: claude-<repo-basename>-<pid>-<rand4>
WDIR_BASE="$(basename "$REPO")"
RAND4="$(head -c 2 /dev/urandom 2>/dev/null | xxd -p 2>/dev/null | head -c 4 || printf '%04x' $((RANDOM % 65536)))"
SESSION_ID="claude-${WDIR_BASE}-$$-${RAND4}"

printf 'CHUMP_SESSION_ID=%s\n' "$SESSION_ID" > "$ENV_FILE"

# Emit ambient event so the fleet can observe when agents self-identify
EMIT="$REPO/scripts/dev/ambient-emit.sh"
if [[ -x "$EMIT" ]]; then
    "$EMIT" agent_session_id_set "session_id=$SESSION_ID pid=$$ env_file=$ENV_FILE" 2>/dev/null || true
fi

exit 0
