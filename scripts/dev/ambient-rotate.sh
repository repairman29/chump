#!/usr/bin/env bash
# ambient-rotate.sh — retention policy for .chump-locks/ambient.jsonl
#
# Keeps events from the last 7 days in-place; archives older events to a gzip
# file named ambient.jsonl.YYYY-MM-DD.gz (dated to the rotation day).
# Appends a {"event":"rotated",...} summary line after the rotation.
# Writes atomically via a tmp file + mv.
#
# Suggested cron: 0 3 * * * /path/to/ambient-rotate.sh
#
# Usage:
#   scripts/dev/ambient-rotate.sh [--dry-run]
#
# Environment:
#   CHUMP_AMBIENT_LOG   override the log path (default: <repo>/.chump-locks/ambient.jsonl)
#   AMBIENT_RETAIN_DAYS number of days to retain (default: 7)

set -euo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
fi

# ── Paths ─────────────────────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then MAIN_REPO="$REPO_ROOT"; else MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"; fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
RETAIN_DAYS="${AMBIENT_RETAIN_DAYS:-7}"

if [[ ! -f "$AMBIENT_LOG" ]]; then
    echo "[ambient-rotate] Nothing to rotate — $AMBIENT_LOG does not exist." >&2
    exit 0
fi

# ── Size threshold ALERT (INFRA-122) ─────────────────────────────────────────
# If the live log has grown unexpectedly large, emit an ambient ALERT so
# operators see it during their next pre-flight tail. Default 50MB; tune
# with AMBIENT_SIZE_ALERT_MB. This catches the case where rotation isn't
# scheduled (or the schedule broke) — even one missed week can push the
# log past the threshold under fleet-load.
SIZE_ALERT_MB="${AMBIENT_SIZE_ALERT_MB:-50}"
SIZE_BYTES="$(stat -f%z "$AMBIENT_LOG" 2>/dev/null || stat -c%s "$AMBIENT_LOG" 2>/dev/null || echo 0)"
SIZE_MB=$(( SIZE_BYTES / 1024 / 1024 ))
if [[ "$SIZE_MB" -ge "$SIZE_ALERT_MB" ]]; then
    ALERT_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    ALERT_LINE="{\"event\":\"ALERT\",\"kind\":\"ambient_oversize\",\"size_mb\":${SIZE_MB},\"threshold_mb\":${SIZE_ALERT_MB},\"note\":\"ambient.jsonl exceeds threshold; rotation may be missing or schedule broken — check launchctl list | grep ambient-rotate\",\"ts\":\"${ALERT_TS}\"}"
    printf '%s\n' "$ALERT_LINE" >> "$AMBIENT_LOG"
    echo "[ambient-rotate] ALERT: ambient.jsonl is ${SIZE_MB}MB (threshold ${SIZE_ALERT_MB}MB) — emitted ambient_oversize event" >&2
fi

# ── Compute cutoff timestamp (YYYY-MM-DDTHH:MM:SSZ, RETAIN_DAYS ago) ─────────
CUTOFF_TS="$(python3 -c "
import datetime
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=${RETAIN_DAYS})
print(cutoff.strftime('%Y-%m-%dT%H:%M:%SZ'))
")"

NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ARCHIVE_DATE="$(date -u +%Y-%m-%d)"
ARCHIVE_PATH="${AMBIENT_LOG}.${ARCHIVE_DATE}.gz"

# ── Split into old (to archive) and recent (to keep) ─────────────────────────
# Python does the split, writes both tmp files, and prints "kept,archived" to stdout.
TMP_KEEP="$(mktemp "${LOCK_DIR}/rotate-keep.XXXXXX")"
TMP_OLD="$(mktemp "${LOCK_DIR}/rotate-old.XXXXXX")"
trap 'rm -f "$TMP_KEEP" "$TMP_OLD"' EXIT

COUNTS="$(python3 - "$AMBIENT_LOG" "$CUTOFF_TS" "$TMP_KEEP" "$TMP_OLD" <<'PYEOF'
import sys, json, datetime

log_path   = sys.argv[1]
cutoff_str = sys.argv[2]
keep_path  = sys.argv[3]
old_path   = sys.argv[4]

cutoff = datetime.datetime.fromisoformat(cutoff_str.replace("Z", "+00:00"))

def parse_ts(s):
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None

kept = 0
archived = 0

with open(log_path) as src, \
     open(keep_path, "w") as keep_f, \
     open(old_path, "w") as old_f:
    for line in src:
        stripped = line.rstrip("\n")
        if not stripped:
            continue
        ts = None
        try:
            ev = json.loads(stripped)
            ts = parse_ts(ev.get("ts", ""))
        except Exception:
            pass
        # Lines with unparseable timestamps are kept (safe default)
        if ts is None or ts >= cutoff:
            keep_f.write(stripped + "\n")
            kept += 1
        else:
            old_f.write(stripped + "\n")
            archived += 1

# Print counts to stdout for shell capture
print(f"{kept},{archived}")
PYEOF
)"

KEPT="${COUNTS%%,*}"
ARCHIVED="${COUNTS##*,}"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[ambient-rotate] DRY-RUN: would keep ${KEPT} events, archive ${ARCHIVED} events older than ${RETAIN_DAYS} days to $(basename "$ARCHIVE_PATH")" >&2
    exit 0
fi

if [[ "$ARCHIVED" -eq 0 ]]; then
    echo "[ambient-rotate] No events older than ${RETAIN_DAYS} days — nothing to rotate." >&2
    exit 0
fi

# ── Archive old events ────────────────────────────────────────────────────────
# If an archive for today already exists, append to it (rare but possible if
# the script is run twice in the same day).
if [[ -f "$ARCHIVE_PATH" ]]; then
    # Decompress existing, append new old lines, recompress
    TMP_COMBINED="$(mktemp "${LOCK_DIR}/rotate-combined.XXXXXX")"
    trap 'rm -f "$TMP_KEEP" "$TMP_OLD" "$TMP_COMBINED"' EXIT
    gzip -dc "$ARCHIVE_PATH" >> "$TMP_COMBINED" || true
    cat "$TMP_OLD" >> "$TMP_COMBINED"
    gzip -c "$TMP_COMBINED" > "${ARCHIVE_PATH}.new"
    mv "${ARCHIVE_PATH}.new" "$ARCHIVE_PATH"
    rm -f "$TMP_COMBINED"
else
    gzip -c "$TMP_OLD" > "$ARCHIVE_PATH"
fi

# ── Build rotation summary line ───────────────────────────────────────────────
SUMMARY_LINE="{\"event\":\"rotated\",\"kept\":${KEPT},\"archived\":${ARCHIVED},\"archive\":\"$(basename "$ARCHIVE_PATH")\",\"cutoff\":\"${CUTOFF_TS}\",\"ts\":\"${NOW_TS}\"}"

# ── Append summary to the keep file, then atomically replace the log ──────────
printf '%s\n' "$SUMMARY_LINE" >> "$TMP_KEEP"
mv "$TMP_KEEP" "$AMBIENT_LOG"

echo "[ambient-rotate] Rotated: kept=${KEPT}, archived=${ARCHIVED} → $(basename "$ARCHIVE_PATH")" >&2
