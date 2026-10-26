#!/usr/bin/env bash
# scripts/hooks/inbox-watcher-nag.sh — INFRA-1941
#
# Non-blocking UserPromptSubmit / PreToolUse nag hook that warns when the
# session's inbox-watcher heartbeat file (.chump-locks/inbox-watcher-${SESSION_ID}.heartbeat)
# is missing or older than 600s.
#
# Opt-out: CHUMP_INBOX_WATCHER_OPTOUT=1 emits kind=inbox_watcher_opted_out and exits 0.
# Debounced to once per 10 minutes via .chump-locks/inbox-watcher-${SESSION_ID}.nag-last.
#
# scanner-anchor: "kind":"inbox_watcher_missing" "kind":"inbox_watcher_opted_out"
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT_FILE="${AMBIENT_JSONL:-$LOCK_DIR/ambient.jsonl}"
SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-default}}"
MAX_AGE_S=600
DEBOUNCE_S=600

mkdir -p "$LOCK_DIR"
now="$(date +%s)"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ "${CHUMP_INBOX_WATCHER_OPTOUT:-0}" == "1" ]]; then
    printf '{"ts":"%s","kind":"inbox_watcher_opted_out","event":"inbox_watcher_opted_out","session":"%s"}\n' \
        "$ts" "$SESSION_ID" >> "$AMBIENT_FILE"
    exit 0
fi

HB_FILE="$LOCK_DIR/inbox-watcher-${SESSION_ID}.heartbeat"
NAG_FILE="$LOCK_DIR/inbox-watcher-${SESSION_ID}.nag-last"

stale=0
age_s=-1
if [[ ! -f "$HB_FILE" ]]; then
    stale=1
else
    mtime="$(stat -f %m "$HB_FILE" 2>/dev/null || stat -c %Y "$HB_FILE" 2>/dev/null || echo 0)"
    age_s=$(( now - mtime ))
    if (( age_s > MAX_AGE_S )); then
        stale=1
    fi
fi

if (( stale == 0 )); then
    exit 0
fi

if [[ -f "$NAG_FILE" ]]; then
    last_nag="$(cat "$NAG_FILE" 2>/dev/null || echo 0)"
    if [[ "$last_nag" =~ ^[0-9]+$ ]] && (( now - last_nag < DEBOUNCE_S )); then
        exit 0
    fi
fi

printf '%s\n' "$now" > "$NAG_FILE"
printf '[inbox-watcher-nag] WARN: inbox watcher heartbeat missing/stale for session=%s (see docs/process/INBOX_WATCHER_PATTERN.md)\n' \
    "$SESSION_ID" >&2
printf '{"ts":"%s","kind":"inbox_watcher_missing","event":"inbox_watcher_missing","session":"%s","age_s":%d}\n' \
    "$ts" "$SESSION_ID" "$age_s" >> "$AMBIENT_FILE"
exit 0
