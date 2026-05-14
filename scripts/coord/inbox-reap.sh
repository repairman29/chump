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

# INFRA-1255: live-inbox cleanup. Two new rules applied BEFORE the
# dead-session archive sweep below:
#   (a) DONE-matched: drop any message whose corr_id == a DONE event's
#       corr_id that landed since the message was written.
#   (b) TTL: drop any message older than CHUMP_INBOX_TTL_DAYS (default 7).
TTL_DAYS="${CHUMP_INBOX_TTL_DAYS:-7}"

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

[[ -d "$INBOX_DIR" ]] || exit 0
shopt -s nullglob

now_epoch="$(date +%s)"
yyyymm="$(date +%Y-%m)"

# ── INFRA-1255 — live-inbox sweep (runs before the dead-session archive pass) ──
# For each live inbox, rewrite the file dropping lines whose corr_id appears
# in a DONE event since the message was written, or which exceed TTL_DAYS.
inbox_reaped_messages=0
for inbox_file in "$INBOX_DIR"/*.jsonl; do
    [[ -f "$inbox_file" ]] || continue
    base="$(basename "$inbox_file" .jsonl)"
    lease_file="$LOCK_DIR/$base.json"
    # Only sweep LIVE inboxes here; dead ones get the existing archive treatment.
    if [[ ! -f "$lease_file" ]]; then continue; fi

    python3 - "$inbox_file" "$AMBIENT" "$TTL_DAYS" "$APPLY" <<'PY' || true
import json, sys, os, time
inbox_path, ambient_path, ttl_days, apply_str = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
apply = apply_str == "1"
now = time.time()
ttl_s = ttl_days * 86400

# Collect DONE corr_ids from ambient (best-effort scan; missing ambient is fine)
done_corr_ids = set()
try:
    with open(ambient_path) as f:
        for line in f:
            try:
                e = json.loads(line)
            except Exception:
                continue
            if e.get('event') == 'DONE':
                cid = e.get('corr_id')
                if cid:
                    done_corr_ids.add(cid)
except FileNotFoundError:
    pass

try:
    with open(inbox_path) as f:
        lines = f.readlines()
except FileNotFoundError:
    sys.exit(0)

keep = []
dropped_done = 0
dropped_ttl = 0
for raw in lines:
    raw_strip = raw.strip()
    if not raw_strip:
        continue
    try:
        e = json.loads(raw_strip)
    except Exception:
        keep.append(raw_strip)
        continue
    # DONE-match: drop the message; the underlying work is finished.
    if e.get('corr_id') and e['corr_id'] in done_corr_ids and e.get('event') != 'DONE':
        dropped_done += 1
        continue
    # TTL
    ts = e.get('ts', '')
    if ts:
        try:
            from datetime import datetime
            t = datetime.fromisoformat(ts.replace('Z', '+00:00')).timestamp()
            if (now - t) > ttl_s:
                dropped_ttl += 1
                continue
        except Exception:
            pass
    keep.append(raw_strip)

if (dropped_done + dropped_ttl) == 0:
    sys.exit(0)

print(f"[inbox-reap] {os.path.basename(inbox_path).replace('.jsonl','')}: drop done={dropped_done} ttl={dropped_ttl} keep={len(keep)}", file=sys.stderr)
if apply:
    with open(inbox_path, 'w') as f:
        for k in keep:
            f.write(k + '\n')
PY
done

# ── Original dead-session archive sweep follows ────────────────────────────────
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
