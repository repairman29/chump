#!/usr/bin/env bash
# compress-stale-archive.sh — RESILIENT-323
#
# REDUCE, don't just reap: gzip data files that are old and no longer
# actively read, in either of two modes:
#
#   --mode docs-archive   (default target: docs/archive) — git-tracked
#     archival data (eval-run .jsonl/.json fixtures, not .md — compressing
#     markdown would break rendered docs). SAFETY: before compressing a
#     candidate, greps the rest of the tracked tree for its basename; any
#     file still referenced by a script/doc is skipped, not compressed.
#
#   --mode runtime-logs   (default target: $CHUMP_STATE_DIR/logs) —
#     untracked launchd/systemd stdout+stderr logs. SAFETY: skips anything
#     modified in the last 24h (still-active) and any *.jsonl append-log
#     (ambient.jsonl, history files) by name pattern.
#
# Usage:
#   compress-stale-archive.sh --mode docs-archive  [--dir PATH] [--min-age-days N] [--execute]
#   compress-stale-archive.sh --mode runtime-logs  [--dir PATH] [--min-age-days N] [--execute]
#
# Default is dry-run; pass --execute to actually gzip+remove originals.
set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-${CHUMP_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/Projects/chump")}}"
STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

MODE="docs-archive"
DIR=""
MIN_AGE_DAYS=""
EXECUTE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)          MODE="$2"; shift 2 ;;
    --dir)           DIR="$2"; shift 2 ;;
    --min-age-days)  MIN_AGE_DAYS="$2"; shift 2 ;;
    --execute)       EXECUTE=1; shift ;;
    --dry-run)       EXECUTE=0; shift ;;
    -h|--help)       sed -n '2,25p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
emit() { [[ -d "$(dirname "$AMBIENT")" ]] && printf '{"ts":"%s",%s}\n' "$(ts)" "$1" >> "$AMBIENT" 2>/dev/null || true; }
# Scanner anchors for the event-registry verify rule:
#   "kind":"storage_archive_compressed"
#   "kind":"storage_archive_compress_skipped"
#   "kind":"storage_archive_compressed_run"

case "$MODE" in
  docs-archive)
    DIR="${DIR:-$REPO_ROOT/docs/archive}"
    MIN_AGE_DAYS="${MIN_AGE_DAYS:-30}"
    ;;
  runtime-logs)
    DIR="${DIR:-$STATE_DIR/logs}"
    MIN_AGE_DAYS="${MIN_AGE_DAYS:-7}"
    ;;
  *) echo "unknown --mode $MODE (want docs-archive|runtime-logs)" >&2; exit 2 ;;
esac

if [[ ! -d "$DIR" ]]; then
  echo "[compress-stale-archive] no such dir: $DIR — nothing to do"
  exit 0
fi

is_referenced() {
  # docs-archive safety: is this basename mentioned anywhere else in the
  # tracked tree (a script/doc that reads it programmatically)?
  local base="$1"
  git -C "$REPO_ROOT" grep -Iq --fixed-strings "$base" -- \
      ':!docs/archive/**' 2>/dev/null
}

git_age_days() {
  # docs-archive files are git-tracked: a fresh checkout stamps every file
  # with today's mtime, so `find -mtime` can't tell old from new. Use the
  # commit history instead — age since the file's LAST commit.
  local f="$1" now epoch
  now="$(date -u +%s)"
  epoch="$(git -C "$REPO_ROOT" log -1 --format=%at -- "$f" 2>/dev/null)"
  [[ -z "$epoch" ]] && { echo 999999; return; }
  echo $(( (now - epoch) / 86400 ))
}

total_before=0
total_after=0
n_compressed=0
n_skipped=0

while IFS= read -r -d '' f; do
  [[ "$f" == *.gz ]] && continue
  case "$MODE" in
    docs-archive)
      # Only jsonl/json — never touch tracked markdown (breaks rendering/links).
      case "$f" in
        *.jsonl|*.json) : ;;
        *) continue ;;
      esac
      if [[ "$(git_age_days "$f")" -lt "$MIN_AGE_DAYS" ]]; then
        continue
      fi
      base="$(basename "$f")"
      if is_referenced "$base"; then
        n_skipped=$((n_skipped + 1))
        emit "\"kind\":\"storage_archive_compress_skipped\",\"file\":\"${f#"$REPO_ROOT"/}\",\"reason\":\"referenced-in-tree\""
        continue
      fi
      ;;
    runtime-logs)
      base="$(basename "$f")"
      case "$base" in
        ambient.jsonl|*.db|*.lock|*history.jsonl) n_skipped=$((n_skipped + 1)); continue ;;
      esac
      ;;
  esac

  size_before="$(du -k "$f" 2>/dev/null | awk '{print $1}')"
  size_before="${size_before:-0}"
  total_before=$((total_before + size_before))

  if [[ "$EXECUTE" -eq 1 ]]; then
    if gzip -9 -f "$f"; then
      size_after="$(du -k "${f}.gz" 2>/dev/null | awk '{print $1}')"
      size_after="${size_after:-0}"
      total_after=$((total_after + size_after))
      n_compressed=$((n_compressed + 1))
      emit "\"kind\":\"storage_archive_compressed\",\"file\":\"${f#"$REPO_ROOT"/}\",\"before_kb\":$size_before,\"after_kb\":$size_after"
    else
      echo "[compress-stale-archive] gzip FAILED: $f" >&2
    fi
  else
    n_compressed=$((n_compressed + 1))
    echo "[compress-stale-archive] would compress: $f (${size_before}KB)"
  fi
done < <(
  if [[ "$MODE" == "docs-archive" ]]; then
    # age gate happens via git_age_days above (mtime is checkout-time, not useful here)
    find "$DIR" -type f -print0 2>/dev/null
  else
    find "$DIR" -type f -mtime "+${MIN_AGE_DAYS}" -print0 2>/dev/null
  fi
)

if [[ "$EXECUTE" -eq 1 ]]; then
  saved=$((total_before - total_after))
  echo "[compress-stale-archive] mode=$MODE dir=$DIR min_age_days=$MIN_AGE_DAYS execute -> compressed=$n_compressed skipped=$n_skipped saved_kb=$saved"
else
  saved=0
  echo "[compress-stale-archive] mode=$MODE dir=$DIR min_age_days=$MIN_AGE_DAYS dry-run -> would_compress=$n_compressed skipped=$n_skipped candidate_kb=$total_before"
fi
emit "\"kind\":\"storage_archive_compressed_run\",\"mode\":\"$MODE\",\"compressed\":$n_compressed,\"skipped\":$n_skipped,\"saved_kb\":$saved,\"candidate_kb\":$total_before,\"dry_run\":$([ "$EXECUTE" -eq 1 ] && echo false || echo true)"

exit 0
