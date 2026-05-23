#!/usr/bin/env bash
# scripts/coord/inbox-poll.sh — INFRA-1860 / INFRA-1879
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

# Need a session id to know which inbox to poll. INFRA-1879 derivation order:
#   1. CHUMP_SESSION_ID env (explicit)
#   2. CLAUDE_SESSION_ID env (Claude Code provides for free)
#   3. tmux pane title (curators run inside tmux panes named curator-opus-*)
#   4. most-recent .chump-locks/claim-*.json (worker sessions with active claim)
#   5. .chump/operator_id file (single-curator-per-machine fallback)
# Path that succeeded is emitted to ambient for observability.
SESSION=""
DERIVATION=""

# Path 1: CHUMP_SESSION_ID
if [[ -n "${CHUMP_SESSION_ID:-}" ]]; then
    SESSION="$CHUMP_SESSION_ID"
    DERIVATION="env_chump"
fi

# Path 2: CLAUDE_SESSION_ID (free from Claude Code)
if [[ -z "$SESSION" && -n "${CLAUDE_SESSION_ID:-}" ]]; then
    # Curator sessions tend to be named curator-opus-<role>-<date>; if the
    # CLAUDE_SESSION_ID happens to match an existing inbox file, use it.
    if [[ -f "$INBOX_DIR/${CLAUDE_SESSION_ID}.jsonl" ]]; then
        SESSION="$CLAUDE_SESSION_ID"
        DERIVATION="env_claude"
    fi
fi

# Path 3: tmux pane title (curators run in tmux panes titled like the session)
if [[ -z "$SESSION" ]] && command -v tmux >/dev/null 2>&1; then
    pane_title="$(tmux display-message -p '#W' 2>/dev/null || echo)"
    if [[ -n "$pane_title" && -f "$INBOX_DIR/${pane_title}.jsonl" ]]; then
        SESSION="$pane_title"
        DERIVATION="tmux_pane"
    fi
fi

# Path 4: most-recent active claim
if [[ -z "$SESSION" ]]; then
    SESSION="$(find "$LOCKS" -maxdepth 1 -name 'claim-*.json' -type f 2>/dev/null \
        | head -1 | xargs -I{} basename {} .json 2>/dev/null | head -c 256 || echo)"
    [[ -n "$SESSION" ]] && DERIVATION="claim_lease"
fi

# Path 5: single-curator-per-machine fallback via .chump/operator_id
if [[ -z "$SESSION" && -f "$REPO/.chump/operator_id" ]]; then
    op_id="$(head -c 256 "$REPO/.chump/operator_id" 2>/dev/null | tr -d '[:space:]')"
    if [[ -n "$op_id" && -f "$INBOX_DIR/${op_id}.jsonl" ]]; then
        SESSION="$op_id"
        DERIVATION="operator_id"
    fi
fi

# No-op if no derivation matched
[[ -z "$SESSION" ]] && exit 0

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

# Audit emit (INFRA-1879: include derivation path for observability)
"$REPO/scripts/dev/ambient-emit.sh" inbox_auto_poll_surfaced \
    "session=$SESSION" "tool_calls_since_last_poll=$THROTTLE_N" \
    "derivation_path=$DERIVATION" 2>/dev/null || true
"$REPO/scripts/dev/ambient-emit.sh" inbox_session_derived \
    "session=$SESSION" "derivation_path=$DERIVATION" 2>/dev/null || true

exit 0
