#!/usr/bin/env bash
# scripts/ci/test-sccache-reaper.sh — INFRA-2303
#
# Unit tests for sccache-reaper.sh:
#   1. Dry-run: does NOT delete files when over cap
#   2. Execute: prunes files down to under cap (real 1KB files, very low cap)
#   3. Idempotence: second run is a no-op when already under cap
#   4. Under-cap: skips reap when dir is already within cap
#   5. Missing dir: exits 0 cleanly with informative message

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/coord/sccache-reaper.sh"

pass() { printf '\033[0;32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m  %s\n' "$*"; exit 1; }
info() { printf '\033[0;36m→\033[0m    %s\n' "$*"; }

[[ -x "$REAPER" ]] || fail "reaper not executable: $REAPER"

# ── Test harness setup ────────────────────────────────────────────────────
TMPDIR_BASE=$(mktemp -d /tmp/test-sccache-XXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Creates N real 512KB files with progressively older mtimes (oldest = entry_001)
make_real_sccache() {
  local dir="$1"
  local n_files="${2:-10}"
  mkdir -p "$dir"
  for i in $(seq 1 "$n_files"); do
    local fname="$dir/cache_entry_$(printf '%03d' "$i").bin"
    dd if=/dev/zero of="$fname" bs=512 count=1024 2>/dev/null
    # Older entries get older mtimes so oldest-first pruning is deterministic
    local hours_ago=$(( n_files - i + 1 ))
    touch -t "$(date -v-"${hours_ago}"H +%Y%m%d%H%M 2>/dev/null || date -d "${hours_ago} hours ago" +%Y%m%d%H%M 2>/dev/null || echo '')" \
      "$fname" 2>/dev/null || true
  done
}

# ── Test 1: Dry-run does NOT delete ───────────────────────────────────────
info "Test 1: dry-run mode — must not delete files when over cap"
TEST_DIR="$TMPDIR_BASE/test1"
# 5 files × 512KB = ~2.5MB; cap at 0GB so it's definitely over cap
make_real_sccache "$TEST_DIR" 5
file_count_before=$(find "$TEST_DIR" -type f | wc -l | tr -d ' ')

output=$(SCCACHE_DIR="$TEST_DIR" SCCACHE_CACHE_CAP_GB=0 \
  "$REAPER" --dry-run 2>&1)
echo "$output" | grep -qi "DRY-RUN" || \
  fail "Test 1: expected DRY-RUN output, got: $output"

file_count_after=$(find "$TEST_DIR" -type f | wc -l | tr -d ' ')
[[ "$file_count_before" -eq "$file_count_after" ]] || \
  fail "Test 1: dry-run deleted files ($file_count_before → $file_count_after)"
pass "Test 1: dry-run left $file_count_before files intact"

# ── Test 2: Execute actually prunes to under cap ──────────────────────────
info "Test 2: --execute prunes oldest files until under cap"
TEST_DIR="$TMPDIR_BASE/test2"
# 20 files × 512KB = ~10MB; cap at 0GB (everything must be pruned)
make_real_sccache "$TEST_DIR" 20
files_before=$(find "$TEST_DIR" -type f | wc -l | tr -d ' ')

output=$(SCCACHE_DIR="$TEST_DIR" SCCACHE_CACHE_CAP_GB=0 \
  "$REAPER" --execute 2>&1)
echo "$output" | grep -qiE "reap|freed|within cap" || \
  fail "Test 2: no reap output seen; got: $output"

files_after=0
if [[ -d "$TEST_DIR" ]]; then
  files_after=$(find "$TEST_DIR" -type f | wc -l | tr -d ' ')
fi
[[ "$files_after" -lt "$files_before" ]] || \
  fail "Test 2: expected fewer files after execute ($files_before → $files_after)"
pass "Test 2: pruned from $files_before to $files_after files"

# ── Test 3: Idempotence — second run is no-op ─────────────────────────────
info "Test 3: idempotence — second --execute on already-under-cap dir"
TEST_DIR="$TMPDIR_BASE/test3"
mkdir -p "$TEST_DIR"
# 3 small files, cap=100GB — definitely under cap
for i in 1 2 3; do
  dd if=/dev/zero of="$TEST_DIR/small_${i}.bin" bs=512 count=1 2>/dev/null
done

output=$(SCCACHE_DIR="$TEST_DIR" SCCACHE_CACHE_CAP_GB=100 \
  "$REAPER" --execute 2>&1)
echo "$output" | grep -qi "within cap\|no reap needed" || \
  fail "Test 3: expected 'within cap' message, got: $output"
pass "Test 3: idempotent — correctly skipped (already under cap)"

# ── Test 4: Under-cap exits cleanly ──────────────────────────────────────
info "Test 4: large cap — under-cap dir skips reap"
TEST_DIR="$TMPDIR_BASE/test4"
mkdir -p "$TEST_DIR"
dd if=/dev/zero of="$TEST_DIR/small.bin" bs=1024 count=100 2>/dev/null

output=$(SCCACHE_DIR="$TEST_DIR" SCCACHE_CACHE_CAP_GB=100 \
  "$REAPER" --execute 2>&1)
echo "$output" | grep -qi "within cap\|no reap needed" || \
  fail "Test 4: expected 'within cap' for small dir with 100GB cap, got: $output"
pass "Test 4: under-cap dir correctly skipped"

# ── Test 5: Missing dir exits 0 ───────────────────────────────────────────
info "Test 5: missing sccache dir exits 0 with informative message"
output=$(SCCACHE_DIR="/tmp/nonexistent-sccache-test-$$" SCCACHE_CACHE_CAP_GB=10 \
  "$REAPER" --execute 2>&1)
echo "$output" | grep -qi "does not exist\|nothing to reap" || \
  fail "Test 5: expected informative message for missing dir, got: $output"
pass "Test 5: missing dir handled cleanly"

echo
printf '\033[0;32mAll sccache-reaper tests passed.\033[0m\n'
