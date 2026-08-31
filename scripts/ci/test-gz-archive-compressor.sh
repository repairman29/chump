#!/usr/bin/env bash
# scripts/ci/test-gz-archive-compressor.sh — RESILIENT-467

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/coord/gz-archive-compressor.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -x "$SCRIPT" ] || fail "gz-archive-compressor.sh missing/not executable"
ok "script exists + executable"

grep -q 'DRY_RUN=1' "$SCRIPT" || fail "must default to dry-run"
ok "defaults to dry-run"

grep -q 'gzip -t' "$SCRIPT" || fail "must verify with gzip -t before removing original"
ok "verifies gzip integrity before removing original"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LOG_DIR="$TMP/logs"
ARCHIVE_DIR="$TMP/archive"
mkdir -p "$LOG_DIR" "$ARCHIVE_DIR"

echo "stale log content" > "$LOG_DIR/stale.log"
touch -d '30 days ago' "$LOG_DIR/stale.log" 2>/dev/null || touch -t 202601010000 "$LOG_DIR/stale.log"

echo "fresh log content" > "$LOG_DIR/fresh.log"

echo "stale archive doc" > "$ARCHIVE_DIR/stale.md"
touch -d '200 days ago' "$ARCHIVE_DIR/stale.md" 2>/dev/null || touch -t 202501010000 "$ARCHIVE_DIR/stale.md"

# Dry-run must not modify anything
CHUMP_GZ_LOG_DIRS="$LOG_DIR" CHUMP_GZ_ARCHIVE_DIRS="$ARCHIVE_DIR" \
  "$SCRIPT" --log-age-days 7 --archive-age-days 90 >/dev/null 2>&1
[ -f "$LOG_DIR/stale.log" ] || fail "dry-run must not remove stale.log"
[ ! -f "$LOG_DIR/stale.log.gz" ] || fail "dry-run must not create stale.log.gz"
ok "dry-run leaves files untouched"

# Execute must compress old files only
CHUMP_GZ_LOG_DIRS="$LOG_DIR" CHUMP_GZ_ARCHIVE_DIRS="$ARCHIVE_DIR" \
  "$SCRIPT" --execute --log-age-days 7 --archive-age-days 90 >/dev/null 2>&1

[ -f "$LOG_DIR/stale.log.gz" ] || fail "stale.log should be compressed to .gz"
[ ! -f "$LOG_DIR/stale.log" ]  || fail "original stale.log should be removed after verified compression"
ok "stale log compressed and original removed"

[ -f "$LOG_DIR/fresh.log" ] || fail "fresh.log (under age threshold) must be left alone"
[ ! -f "$LOG_DIR/fresh.log.gz" ] || fail "fresh.log must not be compressed"
ok "fresh log untouched"

[ -f "$ARCHIVE_DIR/stale.md.gz" ] || fail "stale archive doc should be compressed"
[ ! -f "$ARCHIVE_DIR/stale.md" ] || fail "original stale.md should be removed after verified compression"
ok "stale archive doc compressed and original removed"

gzip -t "$LOG_DIR/stale.log.gz" || fail "compressed log fails gzip integrity check"
gzip -t "$ARCHIVE_DIR/stale.md.gz" || fail "compressed archive doc fails gzip integrity check"
ok "compressed outputs pass gzip -t integrity check"

CONTENT="$(gzip -dc "$LOG_DIR/stale.log.gz")"
[ "$CONTENT" = "stale log content" ] || fail "decompressed content mismatch"
ok "decompressed content matches original"

echo "ALL PASS"
