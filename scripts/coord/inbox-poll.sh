#!/usr/bin/env bash
# scripts/coord/inbox-poll.sh — INFRA-1860
#
# PostToolUse hook helper. Polls the curator's inbox for unread messages and
# outputs them to stdout (which Claude Code surfaces as a system-reminder
# block to the next tool call). Replaces the operator-as-messenger antipattern
# where long-running curator sessions miss broadcast.sh pages because the
# SessionStart inject hook (INFRA-1150) only fires once at startup.
#
# Pattern: read $CHUMP_SESSION_ID's inbox file mtime vs cursor file mtime; if
# inbox newer than cursor, emit unread tail to stdout (with cursor advance).
#
# Throttling: bumps a counter file every invocation; only ACTUALLY polls once
# every N invocations (default N=20) to keep per-tool-call overhead negligible.
#
# Bypass: CHUMP_AUTO_INBOX_POLL=0 short-circuits (no-op).

set -euo pipefail

# Quick bypass
[[ "${CHUMP_AUTO_INBOX_POLL:-1}" == "0" ]] && exit 0

REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCKS="$REPO/.chump-locks"
INBOX_DIR="$LOCKS/inbox"
COUNTER="$LOCKS/inbox-poll-counter"
THROTTLE_N="${CHUMP_INBOX_POLL_N:-20}"

# Need a session id to know which inbox to poll. Curators set this via env
# (CHUMP_SESSION_ID) or it's derivable from .chump-locks/claim-*.json.
SESSION="${CHUMP_SESSION_ID:-}"
if [[ -z "$SESSION" ]]; then
    # Try to find from any active claim lease this process owns.
    # Use find -printf for portability (shellcheck SC2012: don't parse ls).
    SESSION="$(find "$LOCKS" -maxdepth 1 -name 'claim-*.json' -type f 2>/dev/null \
        | head -1 | xargs -I{} basename {} .json | head -c 256 || echo)"
fi
[[ -z "$SESSION" ]] && exit 0  # no session id, nothing to poll

INBOX="$INBOX_DIR/${SESSION}.jsonl"
CURSOR="$INBOX_DIR/${SESSION}.cursor"
[[ ! -f "$INBOX" ]] && exit 0  # no inbox yet, nothing to poll

# Throttle: bump counter, only proceed every Nth call
mkdir -p "$LOCKS"
count="$(cat "$COUNTER" 2>/dev/null || echo 0)"
count=$((count + 1))
echo "$count" > "$COUNTER"
(( count % THROTTLE_N != 0 )) && exit 0

# Compare mtimes: skip if cursor is fresher than inbox
inbox_mtime="$(stat -f %m "$INBOX" 2>/dev/null || stat -c %Y "$INBOX" 2>/dev/null || echo 0)"
cursor_mtime="$(stat -f %m "$CURSOR" 2>/dev/null || stat -c %Y "$CURSOR" 2>/dev/null || echo 0)"
(( inbox_mtime <= cursor_mtime )) && exit 0

# New messages exist — read them via existing chump-inbox.sh
INBOX_TOOL="$REPO/scripts/coord/chump-inbox.sh"
[[ ! -x "$INBOX_TOOL" ]] && exit 0

# Emit unread messages with a header so Claude knows this is async-injected
# inbox content, not a direct user message.
echo "<system-reminder>"
echo "Auto-inbox-poll (INFRA-1860): new messages in your inbox since last check."
echo "Run 'scripts/coord/chump-inbox.sh read' to acknowledge + advance cursor."
echo ""
bash "$INBOX_TOOL" read --session "$SESSION" --limit 5 --no-advance 2>&1 || true
echo "</system-reminder>"

# Audit emit
"$REPO/scripts/dev/ambient-emit.sh" inbox_auto_poll_surfaced \
    "session=$SESSION" "tool_calls_since_last_poll=$THROTTLE_N" 2>/dev/null || true

exit 0
