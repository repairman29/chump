#!/usr/bin/env bash
# ambient-emit.sh — append one event to .chump-locks/ambient.jsonl
#
# Usage:
#   scripts/ambient-emit.sh <event_kind> [key=value ...]
#
# Examples:
#   scripts/ambient-emit.sh session_start gap=FLEET-004a
#   scripts/ambient-emit.sh file_edit path=src/foo.rs
#   scripts/ambient-emit.sh commit sha=abc1234 msg="feat: add thing" gap=FLEET-004a
#   scripts/ambient-emit.sh ALERT kind=lease_overlap sessions=a,b path=src/main.rs
#
# The file is written with a file-lock (flock) so concurrent writers never
# produce interleaved JSON. Falls back to no-lock on systems without flock.
#
# Environment:
#   CHUMP_SESSION_ID   / CLAUDE_SESSION_ID  — used for the session field
#   CHUMP_AMBIENT_LOG  — override the output path (default: .chump-locks/ambient.jsonl)

set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <event_kind> [key=value ...]" >&2
    exit 1
fi

EVENT_KIND="$1"
shift

# ── Paths ─────────────────────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# Linked worktrees have a separate --show-toplevel but share --git-common-dir.
# Resolve the main repo root so all agents write to the same ambient.jsonl.
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
# Worktree-local lock dir: session ID files are scoped per worktree, not shared.
LOCAL_LOCK_DIR="$REPO_ROOT/.chump-locks"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"

mkdir -p "$LOCK_DIR"

# ── Session ID (same precedence as gap-claim.sh) ──────────────────────────────
SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
if [[ -z "$SESSION_ID" ]]; then
    WT_SESSION_CACHE="$LOCAL_LOCK_DIR/.wt-session-id"
    if [[ -f "$WT_SESSION_CACHE" ]]; then
        SESSION_ID="$(cat "$WT_SESSION_CACHE")"
    else
        SESSION_ID="chump-$(basename "$REPO_ROOT")-$(date +%s)"
    fi
fi

# ── Worktree label ────────────────────────────────────────────────────────────
WORKTREE="$(basename "$REPO_ROOT")"

# ── Timestamp ─────────────────────────────────────────────────────────────────
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Build extra fields from key=value args ────────────────────────────────────
EXTRA_JSON=""
for arg in "$@"; do
    KEY="${arg%%=*}"
    VAL="${arg#*=}"
    # Escape value for JSON: backslash, double-quote, control chars
    VAL_ESC="$(printf '%s' "$VAL" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])'  2>/dev/null || printf '%s' "$VAL" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    EXTRA_JSON="${EXTRA_JSON},\"${KEY}\":\"${VAL_ESC}\""
done

# ── Build the JSON line ───────────────────────────────────────────────────────
JSON_LINE="{\"ts\":\"${TS}\",\"session\":\"${SESSION_ID}\",\"worktree\":\"${WORKTREE}\",\"event\":\"${EVENT_KIND}\"${EXTRA_JSON}}"

# ── Atomic append (flock if available, plain >> otherwise) ───────────────────
if command -v flock &>/dev/null; then
    (
        flock -x 200
        printf '%s\n' "$JSON_LINE" >> "$AMBIENT_LOG"
    ) 200>"${AMBIENT_LOG}.lock"
else
    # macOS: no flock, use noclobber trick — races are rare enough at human timescales
    printf '%s\n' "$JSON_LINE" >> "$AMBIENT_LOG"
fi

# ── FLEET-006: best-effort NATS dual-emit ─────────────────────────────────────
# When chump-coord is on PATH, fan the same event out to JetStream so
# remote machines (and Cold Water) can see it. No-op when chump-coord or
# NATS are unavailable — file append above is the durable record.
if [[ "${CHUMP_AMBIENT_NATS:-1}" != "0" ]] && command -v chump-coord &>/dev/null; then
    # Translate event kind to upper-case for chump.events.<lower> subject
    # consistency with broadcast.sh; pass-through key=value args.
    CHUMP_SESSION_ID="$SESSION_ID" \
        chump-coord emit "$EVENT_KIND" "$@" >/dev/null 2>&1 || true
fi
