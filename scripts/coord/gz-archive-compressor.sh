#!/usr/bin/env bash
# gz-archive-compressor.sh — RESILIENT-467 (RESILIENT-323 slice)
#
# Compresses stale logs and archived docs to .gz to bound disk footprint.
# Two independent sweeps, each: find candidates older than a threshold ->
# gzip -> verify with `gzip -t` -> remove original ONLY on verified success.
#
#   1. Logs sweep    — *.log files under LOG_DIRS older than LOG_AGE_DAYS.
#   2. Archive sweep — files under ARCHIVE_DIRS (docs/archive, scripts/archived)
#                       older than ARCHIVE_AGE_DAYS.
#
# Already-compressed (.gz), currently-open, or actively-leased files are
# skipped. Dry-run by default; pass --execute to actually compress+remove.
#
# Usage:
#   gz-archive-compressor.sh [--execute] [--log-age-days N] [--archive-age-days N]
#
# Environment:
#   CHUMP_GZ_LOG_DIRS        colon-separated list (default: logs:sessions:.chump-locks)
#   CHUMP_GZ_ARCHIVE_DIRS    colon-separated list (default: docs/archive:scripts/archived)
#   CHUMP_GZ_LOG_AGE_DAYS    default: 14
#   CHUMP_GZ_ARCHIVE_AGE_DAYS default: 90

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

source "$REPO_ROOT/scripts/coord/lib/ambient-write.sh"

DRY_RUN=1
LOG_AGE_DAYS="${CHUMP_GZ_LOG_AGE_DAYS:-14}"
ARCHIVE_AGE_DAYS="${CHUMP_GZ_ARCHIVE_AGE_DAYS:-90}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute) DRY_RUN=0; shift ;;
    --log-age-days) LOG_AGE_DAYS="$2"; shift 2 ;;
    --archive-age-days) ARCHIVE_AGE_DAYS="$2"; shift 2 ;;
    --help|-h) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

IFS=':' read -r -a LOG_DIRS <<<"${CHUMP_GZ_LOG_DIRS:-logs:sessions:.chump-locks}"
IFS=':' read -r -a ARCHIVE_DIRS <<<"${CHUMP_GZ_ARCHIVE_DIRS:-docs/archive:scripts/archived}"

AMBIENT_LOG="$REPO_ROOT/.chump-locks/ambient.jsonl"

compressed_count=0
skipped_count=0
bytes_saved=0

# compress_file <path>
# gzip to <path>.gz, verify with gzip -t, remove original only after verify
# succeeds. Never overwrites an existing .gz (skips instead).
compress_file() {
  local f="$1"
  local out="${f}.gz"

  if [[ -e "$out" ]]; then
    echo "[gz-archive] skip (already has .gz): $f" >&2
    skipped_count=$((skipped_count + 1))
    return
  fi

  # Skip files that look actively held (open write fd) — best-effort guard,
  # not a hard lock (lsof may be unavailable).
  if command -v lsof >/dev/null 2>&1 && lsof -- "$f" >/dev/null 2>&1; then
    echo "[gz-archive] skip (open fd): $f" >&2
    skipped_count=$((skipped_count + 1))
    return
  fi

  local size_before
  size_before=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[gz-archive] DRY-RUN: would compress $f (${size_before} bytes)" >&2
    return
  fi

  if ! gzip -c "$f" > "$out.tmp"; then
    echo "[gz-archive] ERROR: gzip failed for $f" >&2
    rm -f "$out.tmp"
    return
  fi
  mv "$out.tmp" "$out"

  if ! gzip -t "$out" 2>/dev/null; then
    echo "[gz-archive] ERROR: verification failed for $out — leaving original in place" >&2
    rm -f "$out"
    return
  fi

  rm -f "$f"
  local size_after
  size_after=$(stat -c%s "$out" 2>/dev/null || stat -f%z "$out" 2>/dev/null || echo 0)
  bytes_saved=$((bytes_saved + size_before - size_after))
  compressed_count=$((compressed_count + 1))
  echo "[gz-archive] compressed: $f -> $out (${size_before} -> ${size_after} bytes)" >&2
}

sweep_dir() {
  local dir="$1"
  local age_days="$2"
  local name_pattern="$3"

  [[ -d "$dir" ]] || return 0

  while IFS= read -r -d '' f; do
    compress_file "$f"
  done < <(find "$dir" -type f -name "$name_pattern" -mtime "+${age_days}" ! -name '*.gz' -print0 2>/dev/null)
}

echo "[gz-archive] log sweep: age > ${LOG_AGE_DAYS}d, dirs: ${LOG_DIRS[*]}" >&2
for d in "${LOG_DIRS[@]}"; do
  sweep_dir "$d" "$LOG_AGE_DAYS" '*.log'
  sweep_dir "$d" "$LOG_AGE_DAYS" '*.jsonl.[0-9]*'
done

echo "[gz-archive] archive sweep: age > ${ARCHIVE_AGE_DAYS}d, dirs: ${ARCHIVE_DIRS[*]}" >&2
for d in "${ARCHIVE_DIRS[@]}"; do
  sweep_dir "$d" "$ARCHIVE_AGE_DAYS" '*.md'
  sweep_dir "$d" "$ARCHIVE_AGE_DAYS" '*.txt'
  sweep_dir "$d" "$ARCHIVE_AGE_DAYS" '*.json'
done

if [[ "$DRY_RUN" -eq 0 ]]; then
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # scanner-anchor: "kind":"gz_archive_compressed"
  LINE="$(printf '{"ts":"%s","kind":"gz_archive_compressed","compressed":%d,"skipped":%d,"bytes_saved":%d}' \
    "$TS" "$compressed_count" "$skipped_count" "$bytes_saved")"
  if [[ -d "$REPO_ROOT/.chump-locks" ]]; then
    _ambient_write "$AMBIENT_LOG" "$LINE"
  fi
  echo "[gz-archive] done: compressed=${compressed_count} skipped=${skipped_count} bytes_saved=${bytes_saved}" >&2
else
  echo "[gz-archive] DRY-RUN complete — pass --execute to apply" >&2
fi
