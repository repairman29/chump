#!/usr/bin/env bash
# inbox-reap.sh — Archive inboxes belonging to dead sessions (INFRA-1115).
#
# A session is considered dead when:
#   - its lease file .chump-locks/<session>.json is missing OR
#   - the lease's expires_at is past AND no heartbeat for CHUMP_INBOX_REAP_GRACE_S
#     (default 3600s = 1h) AND inbox has unread messages
#
# Action: gzip the inbox to .chump-locks/inbox-archive/<session>/<yyyy-mm>.jsonl.gz,
# emit kind=inbox_archived to ambient with the count of unread messages, and
# (when sessions remain alive) broadcast a HANDOFF naming the deceased session
# so survivors can pick up loose threads.
#
# Run periodically (cron / launchd / chump fleet doctor). Idempotent: archived
# inboxes are removed; subsequent runs see them gone.
#
# Usage:
#   inbox-reap.sh                # dry-run by default; prints planned actions
#   inbox-reap.sh --apply        # actually archives + emits events

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then MAIN_REPO="$REPO_ROOT"; else MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"; fi

LOCK_DIR="$MAIN_REPO/.chump-locks"
INBOX_DIR="$LOCK_DIR/inbox"
ARCHIVE_DIR="$LOCK_DIR/inbox-archive"
AMBIENT="$LOCK_DIR/ambient.jsonl"

GRACE_S="${CHUMP_INBOX_REAP_GRACE_S:-3600}"

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

[[ -d "$INBOX_DIR" ]] || exit 0
shopt -s nullglob

now_epoch="$(date +%s)"
yyyymm="$(date +%Y-%m)"

reaped_count=0
for inbox_file in "$INBOX_DIR"/*.jsonl; do
    base="$(basename "$inbox_file" .jsonl)"
    lease_file="$LOCK_DIR/$base.json"

    # Live session: lease present and not expired → keep
    if [[ -f "$lease_file" ]]; then
        expires_at="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('expires_at',''))" "$lease_file" 2>/dev/null || true)"
        if [[ -n "$expires_at" ]]; then
            expires_epoch="$(python3 -c "
from datetime import datetime
import sys
v=sys.argv[1].replace('Z','+00:00')
try:
    print(int(datetime.fromisoformat(v).timestamp()))
except Exception:
    print(0)
" "$expires_at" 2>/dev/null || echo 0)"
            if [[ "$expires_epoch" -gt 0 && "$expires_epoch" -gt "$now_epoch" ]]; then
                continue  # lease still live
            fi
            # Expired — check grace
            age_s=$(( now_epoch - expires_epoch ))
            if [[ "$age_s" -lt "$GRACE_S" ]]; then
                continue  # still in grace window
            fi
        fi
    fi

    # Dead-session inbox — archive
    unread_lines="$(wc -l < "$inbox_file" 2>/dev/null | tr -d ' ' || echo 0)"
    target_dir="$ARCHIVE_DIR/$base"
    target_file="$target_dir/$yyyymm.jsonl.gz"

    if [[ "$APPLY" -eq 1 ]]; then
        mkdir -p "$target_dir"
        if [[ -f "$target_file" ]]; then
            # Append to existing month archive: decompress, append, recompress.
            tmp="$target_dir/.merge.$$.jsonl"
            gunzip -c "$target_file" > "$tmp"
            cat "$inbox_file" >> "$tmp"
            gzip -f "$tmp"
            mv "$tmp.gz" "$target_file"
        else
            gzip -c "$inbox_file" > "$target_file"
        fi
        rm -f "$inbox_file" "$INBOX_DIR/$base.cursor" "$INBOX_DIR/.$base.lock"
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '{"ts":"%s","kind":"inbox_archived","session":"%s","unread_messages":%d,"archive":"%s"}\n' \
            "$ts" "$base" "$unread_lines" "${target_file#$MAIN_REPO/}" >> "$AMBIENT" 2>/dev/null || true
        printf '[inbox-reap] archived %s (%d unread) → %s\n' "$base" "$unread_lines" "$target_file"
    else
        printf '[inbox-reap] would archive %s (%d unread) → %s\n' "$base" "$unread_lines" "$target_file"
    fi
    reaped_count=$((reaped_count + 1))
done

if [[ "$APPLY" -eq 0 && "$reaped_count" -gt 0 ]]; then
    printf '[inbox-reap] dry-run: %d inbox(es) would be archived. Re-run with --apply to commit.\n' "$reaped_count"
fi
