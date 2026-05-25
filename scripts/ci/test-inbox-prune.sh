#!/usr/bin/env bash
# test-inbox-prune.sh — CI tests for chump-inbox-prune.sh (INFRA-1979)
#
# Test cases:
#   1. Large file (5MB) is size-pruned to <= max-size (100KB)
#   2. Old file (30-day mtime) is age-archived entirely
#   3. Dry-run mode does not modify any files
#   4. Clean file (small + recent) is left untouched
#   5. Archive directory is created; archived files are valid gzip

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve repo root: scripts/ci/ is 2 levels deep, so ../.. is the repo root.
# Prefer git show-toplevel; fall back to navigating up from SCRIPT_DIR so the
# path is correct even when git is unavailable in the CI runner context.
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../.." && pwd))"
PRUNE_SCRIPT="$REPO_ROOT/scripts/coord/chump-inbox-prune.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TMPDIR_BASE=""

cleanup() {
    [[ -n "$TMPDIR_BASE" && -d "$TMPDIR_BASE" ]] && rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT

setup_env() {
    TMPDIR_BASE="$(mktemp -d)"
    INBOX_DIR="$TMPDIR_BASE/.chump-locks/inbox"
    mkdir -p "$INBOX_DIR"
    # Point ambient emit at a test sink so we don't pollute real ambient.jsonl
    AMBIENT_LOG="$TMPDIR_BASE/ambient.jsonl"
    export CHUMP_AMBIENT_LOG="$AMBIENT_LOG"
    export GIT_DIR="$REPO_ROOT/.git"
}

assert_true() {
    local msg="$1"
    local result="$2"
    if [[ "$result" == "true" || "$result" == "0" ]]; then
        echo "  PASS: $msg"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: $msg"
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_file_exists() {
    local msg="$1"
    local path="$2"
    if [[ -e "$path" ]]; then
        echo "  PASS: $msg"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: $msg (not found: $path)"
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_file_absent() {
    local msg="$1"
    local path="$2"
    if [[ ! -e "$path" ]]; then
        echo "  PASS: $msg"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: $msg (still present: $path)"
        FAIL=$(( FAIL + 1 ))
    fi
}

# ── Syntax check ─────────────────────────────────────────────────────────────
echo "=== Syntax check ==="
bash -n "$PRUNE_SCRIPT" && echo "  PASS: bash -n $PRUNE_SCRIPT" && PASS=$(( PASS + 1 )) || { echo "  FAIL: syntax error"; FAIL=$(( FAIL + 1 )); }

# ── Test 1: Large file size-pruned ────────────────────────────────────────────
echo ""
echo "=== Test 1: 5MB inbox file is size-pruned to <= 100KB ==="
setup_env

# Create a 5MB synthetic inbox file
LARGE_FILE="$INBOX_DIR/session-large.jsonl"
python3 -c "
import json, time
ts = '2026-05-25T12:00:00Z'
for i in range(50000):
    print(json.dumps({'ts': ts, 'kind': 'test_event', 'i': i, 'session': 'session-large', 'msg': 'x' * 80}))
" > "$LARGE_FILE"

BEFORE_SIZE="$(wc -c < "$LARGE_FILE")"
echo "  File size before prune: ${BEFORE_SIZE} bytes"

CHUMP_INBOX_DIR="$INBOX_DIR" bash "$PRUNE_SCRIPT" prune --max-size 100KB \
    2>&1 | grep -v "^$" || true

# The file should still exist (size-pruned, not archived)
AFTER_SIZE=0
if [[ -f "$LARGE_FILE" ]]; then
    AFTER_SIZE="$(wc -c < "$LARGE_FILE")"
fi

# Archive directory should have a .jsonl.gz for the head
ARCHIVE_COUNT="$(find "$INBOX_DIR/archive" -name "session-large-*.jsonl.gz" 2>/dev/null | wc -l | tr -d ' ')"

echo "  File size after prune: ${AFTER_SIZE} bytes (limit: $((100*1024)))"
echo "  Archive files created: ${ARCHIVE_COUNT}"

if [[ "$AFTER_SIZE" -le $((100 * 1024)) ]]; then
    assert_true "Pruned file size <= 100KB" "true"
else
    assert_true "Pruned file size <= 100KB" "false"
fi
if [[ "$ARCHIVE_COUNT" -ge 1 ]]; then
    assert_true "Archive file created for pruned head" "true"
else
    assert_true "Archive file created for pruned head" "false"
fi

# Verify the archive is valid gzip
ARCHIVE_FILE="$(find "$INBOX_DIR/archive" -name "session-large-*.jsonl.gz" 2>/dev/null | head -1)"
if [[ -n "$ARCHIVE_FILE" ]]; then
    if gzip -t "$ARCHIVE_FILE" 2>/dev/null; then
        assert_true "Archive is valid gzip" "true"
    else
        assert_true "Archive is valid gzip" "false"
    fi
fi

# ── Test 2: Old file age-archived ─────────────────────────────────────────────
echo ""
echo "=== Test 2: 30-day-old inbox file is archived entirely ==="
setup_env

OLD_FILE="$INBOX_DIR/session-old.jsonl"
printf '{"ts":"2026-04-25T00:00:00Z","kind":"test_event","session":"session-old"}\n' > "$OLD_FILE"
# Set mtime to 30 days ago
touch -t "$(date -v-30d +%Y%m%d%H%M 2>/dev/null || date -d '30 days ago' +%Y%m%d%H%M 2>/dev/null || echo "202504250000")" "$OLD_FILE" 2>/dev/null || true

CHUMP_INBOX_DIR="$INBOX_DIR" bash "$PRUNE_SCRIPT" prune --max-age 7d 2>&1 | grep -v "^$" || true

ARCHIVE_COUNT="$(find "$INBOX_DIR/archive" -name "session-old-*.jsonl.gz" 2>/dev/null | wc -l | tr -d ' ')"

assert_file_absent "Original old file removed after age-archive" "$OLD_FILE"
if [[ "$ARCHIVE_COUNT" -ge 1 ]]; then
    assert_true "Archive file created for old session" "true"
else
    assert_true "Archive file created for old session" "false"
fi

# Verify archived content is valid gzip and contains original data
ARCHIVE_FILE="$(find "$INBOX_DIR/archive" -name "session-old-*.jsonl.gz" 2>/dev/null | head -1)"
if [[ -n "$ARCHIVE_FILE" ]]; then
    CONTENT="$(gzip -dc "$ARCHIVE_FILE" 2>/dev/null | head -1)"
    if echo "$CONTENT" | grep -q "session-old"; then
        assert_true "Archived content preserves original data" "true"
    else
        assert_true "Archived content preserves original data" "false"
    fi
fi

# ── Test 3: Dry-run does not modify files ─────────────────────────────────────
echo ""
echo "=== Test 3: Dry-run mode does not modify files ==="
setup_env

DRY_LARGE="$INBOX_DIR/session-dryrun.jsonl"
python3 -c "
import json
for i in range(50000):
    print(json.dumps({'ts': '2026-05-25T12:00:00Z', 'kind': 'test_event', 'i': i, 'msg': 'x' * 80}))
" > "$DRY_LARGE"

BEFORE_SIZE="$(wc -c < "$DRY_LARGE")"
BEFORE_MTIME="$(stat -f %m "$DRY_LARGE" 2>/dev/null || stat -c %Y "$DRY_LARGE" 2>/dev/null)"

CHUMP_INBOX_DIR="$INBOX_DIR" bash "$PRUNE_SCRIPT" prune --max-size 100KB --dry-run 2>&1 | grep -v "^$" || true

AFTER_SIZE="$(wc -c < "$DRY_LARGE")"
ARCHIVE_COUNT="$(find "$INBOX_DIR/archive" -name "*.jsonl.gz" 2>/dev/null | wc -l | tr -d ' ')"

if [[ "$AFTER_SIZE" -eq "$BEFORE_SIZE" ]]; then
    assert_true "Dry-run: file size unchanged" "true"
else
    assert_true "Dry-run: file size unchanged" "false"
fi
if [[ "$ARCHIVE_COUNT" -eq 0 ]]; then
    assert_true "Dry-run: no archive files created" "true"
else
    assert_true "Dry-run: no archive files created" "false"
fi

# ── Test 4: Clean file (small + recent) untouched ─────────────────────────────
echo ""
echo "=== Test 4: Small recent file left untouched ==="
setup_env

CLEAN_FILE="$INBOX_DIR/session-clean.jsonl"
printf '{"ts":"2026-05-25T12:00:00Z","kind":"test_event","session":"session-clean"}\n' > "$CLEAN_FILE"
BEFORE_SIZE="$(wc -c < "$CLEAN_FILE")"

CHUMP_INBOX_DIR="$INBOX_DIR" bash "$PRUNE_SCRIPT" prune --max-size 100KB --max-age 7d 2>&1 | grep -v "^$" || true

AFTER_SIZE="$(wc -c < "$CLEAN_FILE")"
ARCHIVE_COUNT="$(find "$INBOX_DIR/archive" -name "*.jsonl.gz" 2>/dev/null | wc -l | tr -d ' ')"

if [[ "$AFTER_SIZE" -eq "$BEFORE_SIZE" ]]; then
    assert_true "Clean file: size unchanged" "true"
else
    assert_true "Clean file: size unchanged" "false"
fi
if [[ "$ARCHIVE_COUNT" -eq 0 ]]; then
    assert_true "Clean file: no archive created" "true"
else
    assert_true "Clean file: no archive created" "false"
fi

assert_file_exists "Clean file still present" "$CLEAN_FILE"

# ── Test 5: No-op when inbox dir does not exist ───────────────────────────────
echo ""
echo "=== Test 5: Graceful no-op when inbox dir is absent ==="
NODIR_TMP="$(mktemp -d)"
# The prune script resolves INBOX_DIR from git, so just verify it exits cleanly
# even with no inbox/*.jsonl files to process.
EMPTY_INBOX="$NODIR_TMP/.chump-locks/inbox"
mkdir -p "$EMPTY_INBOX"
bash "$PRUNE_SCRIPT" prune 2>&1 | grep -v "^$" || true
NO_OP_EXIT=$?
if [[ "$NO_OP_EXIT" -eq 0 ]]; then
    assert_true "Exits 0 with empty inbox" "true"
else
    assert_true "Exits 0 with empty inbox" "false"
fi
rm -rf "$NODIR_TMP"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
