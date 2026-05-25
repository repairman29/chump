#!/usr/bin/env bash
# chump-inbox-prune.sh — Size and age rotation for .chump-locks/inbox/*.jsonl files.
#
# INFRA-1979: broadcast.sh appends to inbox files without any rotation cap.
# Files reach 50KB+ per session during normal fleet operation; under prolonged
# runs they grow to MB scale, slowing tail-reads and accumulating disk waste.
#
# Usage:
#   chump-inbox-prune.sh prune [--max-age <duration>] [--max-size <size>] [--dry-run]
#   chump-inbox-prune.sh --help
#
# Subcommands:
#   prune     Prune all inbox files that exceed size or age thresholds
#
# Flags:
#   --max-age <N>[d|h]   Archive files older than N days/hours (default: 7d)
#   --max-size <N>[KB|MB] Truncate files larger than threshold (default: 100KB)
#   --dry-run            Print what would be done; do not modify any files
#
# Size pruning: if file > max-size, keep the most-recent bytes/lines that fit
# within max-size; archive older portion to
#   .chump-locks/inbox/archive/<session-id>-<ts>.jsonl.gz
#
# Age pruning: if file mtime older than max-age, gzip-archive entirely.
#
# Emits: kind=inbox_pruned to ambient.jsonl with pruned_count + bytes_freed.
#
# Idempotent: safe to run repeatedly; no-ops on files that are already within
# limits. Dry-run never modifies files.
#
# scanner-anchor: "kind":"inbox_pruned"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi

LOCK_DIR="$MAIN_REPO/.chump-locks"
# CHUMP_INBOX_DIR can be overridden in tests so the prune script operates on
# a synthetic inbox rather than the live .chump-locks/inbox directory.
INBOX_DIR="${CHUMP_INBOX_DIR:-$LOCK_DIR/inbox}"
ARCHIVE_DIR="$INBOX_DIR/archive"
EMIT_SCRIPT="$REPO_ROOT/scripts/dev/ambient-emit.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
MAX_AGE_DAYS=7
MAX_SIZE_BYTES=$((100 * 1024))   # 100 KB
DRY_RUN=false
SUBCOMMAND=""

# ── Parse arguments ────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
chump-inbox-prune.sh — inbox .jsonl rotation daemon helper

Usage:
  chump-inbox-prune.sh prune [--max-age <duration>] [--max-size <size>] [--dry-run]
  chump-inbox-prune.sh --help

Subcommands:
  prune        Prune inbox files that exceed size or age limits

Flags:
  --max-age <N>[d|h]     Max file age before archiving (default: 7d)
  --max-size <N>[KB|MB]  Max file size before truncating (default: 100KB)
  --dry-run              Print planned actions; do not modify files

Examples:
  chump-inbox-prune.sh prune
  chump-inbox-prune.sh prune --max-age 3d --max-size 50KB
  chump-inbox-prune.sh prune --dry-run
EOF
}

parse_size() {
    local raw="$1"
    local num="${raw//[^0-9]/}"
    local unit
    unit="$(printf '%s' "${raw//[0-9]/}" | tr '[:lower:]' '[:upper:]')"
    case "$unit" in
        KB|K) echo $(( num * 1024 )) ;;
        MB|M) echo $(( num * 1024 * 1024 )) ;;
        GB|G) echo $(( num * 1024 * 1024 * 1024 )) ;;
        *)    echo "$num" ;;
    esac
}

parse_age_days() {
    local raw="$1"
    local num="${raw//[^0-9]/}"
    local unit
    unit="$(printf '%s' "${raw//[0-9]/}" | tr '[:lower:]' '[:upper:]')"
    case "$unit" in
        D|"")   echo "$num" ;;
        H)      printf '%.4f\n' "$(echo "$num / 24" | bc -l)" ;;
        *)      echo "$num" ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        prune)
            SUBCOMMAND="prune"
            shift
            ;;
        --max-age)
            MAX_AGE_DAYS="$(parse_age_days "$2")"
            shift 2
            ;;
        --max-size)
            MAX_SIZE_BYTES="$(parse_size "$2")"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$SUBCOMMAND" ]]; then
    echo "Error: subcommand required (e.g. prune)" >&2
    usage
    exit 1
fi

# ── Prune logic ───────────────────────────────────────────────────────────────
do_prune() {
    local pruned_count=0
    local bytes_freed=0

    # Skip if inbox dir doesn't exist yet
    if [[ ! -d "$INBOX_DIR" ]]; then
        echo "[inbox-prune] No inbox directory found at $INBOX_DIR — nothing to prune."
        return 0
    fi

    mkdir -p "$ARCHIVE_DIR"

    local now_epoch
    now_epoch="$(date +%s)"
    local max_age_secs
    # bc handles fractional days for hours input
    max_age_secs="$(echo "$MAX_AGE_DAYS * 86400" | bc | xargs printf '%.0f')"

    while IFS= read -r -d '' inbox_file; do
        local filename
        filename="$(basename "$inbox_file")"
        local session_id="${filename%.jsonl}"

        # Get file size
        local file_size
        file_size="$(wc -c < "$inbox_file")"

        # Get file mtime epoch
        local mtime_epoch
        if stat --version 2>/dev/null | grep -q GNU; then
            # GNU stat (Linux)
            mtime_epoch="$(stat -c %Y "$inbox_file")"
        else
            # BSD stat (macOS)
            mtime_epoch="$(stat -f %m "$inbox_file")"
        fi
        local age_secs=$(( now_epoch - mtime_epoch ))

        # Age pruning: whole-file archive
        if [[ "$age_secs" -gt "$max_age_secs" ]]; then
            local ts_tag
            ts_tag="$(date -u +%Y%m%dT%H%M%SZ)"
            local archive_name="${session_id}-${ts_tag}.jsonl.gz"
            if [[ "$DRY_RUN" == "true" ]]; then
                echo "[inbox-prune] DRY-RUN: would archive by age: $inbox_file -> $ARCHIVE_DIR/$archive_name"
            else
                gzip -c "$inbox_file" > "$ARCHIVE_DIR/$archive_name"
                rm -f "$inbox_file"
                echo "[inbox-prune] Archived by age: $filename -> archive/$archive_name"
            fi
            pruned_count=$(( pruned_count + 1 ))
            bytes_freed=$(( bytes_freed + file_size ))
            continue
        fi

        # Size pruning: keep tail that fits within limit, archive head
        if [[ "$file_size" -gt "$MAX_SIZE_BYTES" ]]; then
            local ts_tag
            ts_tag="$(date -u +%Y%m%dT%H%M%SZ)"
            local archive_name="${session_id}-${ts_tag}.jsonl.gz"
            local keep_bytes="$MAX_SIZE_BYTES"
            # Calculate offset from which to keep (byte count from end)
            local drop_bytes=$(( file_size - keep_bytes ))

            if [[ "$DRY_RUN" == "true" ]]; then
                echo "[inbox-prune] DRY-RUN: would size-prune $inbox_file (${file_size}B > ${MAX_SIZE_BYTES}B); archive ${drop_bytes}B head"
            else
                # Archive the head (bytes we're dropping)
                head -c "$drop_bytes" "$inbox_file" | gzip -c > "$ARCHIVE_DIR/$archive_name"
                # Keep only the tail
                local tmp_file
                tmp_file="$(mktemp "${inbox_file}.XXXXXX")"
                tail -c "$keep_bytes" "$inbox_file" > "$tmp_file"
                mv "$tmp_file" "$inbox_file"
                echo "[inbox-prune] Size-pruned: $filename (${file_size}B -> ${keep_bytes}B), archived head to archive/$archive_name"
            fi
            pruned_count=$(( pruned_count + 1 ))
            bytes_freed=$(( bytes_freed + drop_bytes ))
        fi

    done < <(find "$INBOX_DIR" -maxdepth 1 -name "*.jsonl" -print0)

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[inbox-prune] DRY-RUN complete: would prune ${pruned_count} files, free ${bytes_freed} bytes"
    else
        echo "[inbox-prune] Done: pruned ${pruned_count} files, freed ${bytes_freed} bytes"

        # Emit ambient event
        local session_id_val="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-inbox-prune-$$}}"
        local ts
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        local json
        json="{\"ts\":\"${ts}\",\"kind\":\"inbox_pruned\",\"session\":\"${session_id_val}\",\"pruned_count\":${pruned_count},\"bytes_freed\":${bytes_freed}}"

        if [[ -x "$EMIT_SCRIPT" ]]; then
            echo "$json" | "$EMIT_SCRIPT" 2>/dev/null || true
        else
            # Fallback: append directly
            local tmp
            tmp="$(mktemp "$LOCK_DIR/.inbox_prune_XXXXXX")"
            printf '%s\n' "$json" >> "$tmp"
            cat "$tmp" >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
            rm -f "$tmp"
        fi
    fi
}

case "$SUBCOMMAND" in
    prune) do_prune ;;
esac
