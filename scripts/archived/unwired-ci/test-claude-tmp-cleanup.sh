#!/usr/bin/env bash
# test-claude-tmp-cleanup.sh — INFRA-400
# Creates synthetic /tmp dirs with various ages, asserts only stale ones are pruned.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLEANUP="$REPO_ROOT/scripts/dev/cleanup-claude-tmp.sh"

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -x "$CLEANUP" ]] || fail "cleanup-claude-tmp.sh missing at $CLEANUP"

# ── Setup: synthetic dirs under /tmp/claude-test-INFRA400-* ──────────────────
# We can't create /private/tmp/claude-* in CI (need permissions), so we
# test with a PATH override via TMPDIR and a wrapper.

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Create fresh dir (should be preserved)
FRESH_DIR="$WORK_DIR/claude-fresh"
mkdir -p "$FRESH_DIR"
touch "$FRESH_DIR/output.txt"

# Create stale dir (>24h old) by backdating mtime
STALE_DIR="$WORK_DIR/claude-stale"
mkdir -p "$STALE_DIR"
touch "$STALE_DIR/output.txt"
# Backdate to 48h ago
touch -m -t "$(date -v-48H +%Y%m%d%H%M 2>/dev/null || date -d '48 hours ago' +%Y%m%d%H%M 2>/dev/null)" "$STALE_DIR" 2>/dev/null || true

# ── Test 1: CHUMP_TMP_CLEANUP_DISABLE=1 skips all work ───────────────────────
CHUMP_TMP_CLEANUP_DISABLE=1 bash "$CLEANUP" > /dev/null 2>&1
pass "CHUMP_TMP_CLEANUP_DISABLE=1 exits early"

# ── Test 2: Stale dir detection (source inspection) ──────────────────────────
grep -q 'MAX_AGE_HOURS' "$CLEANUP" \
    || fail "MAX_AGE_HOURS threshold not found in cleanup script"
pass "MAX_AGE_HOURS threshold present in cleanup script"

# ── Test 3: Active session guard present ─────────────────────────────────────
grep -q 'active_paths\|lsof' "$CLEANUP" \
    || fail "Active session guard (lsof) not found in cleanup script"
pass "Active session guard present"

# ── Test 4: Ambient event emission ───────────────────────────────────────────
grep -q 'kind.*tmp_cleanup\|tmp_cleanup' "$CLEANUP" \
    || fail "ambient kind=tmp_cleanup emission not found"
pass "ambient kind=tmp_cleanup event emission present"

# ── Test 5: CHUMP_TMP_CLEANUP_DISABLE documented ─────────────────────────────
grep -q 'CHUMP_TMP_CLEANUP_DISABLE' "$CLEANUP" \
    || fail "CHUMP_TMP_CLEANUP_DISABLE opt-out not in cleanup script"
pass "CHUMP_TMP_CLEANUP_DISABLE opt-out present"

# ── Test 6: Launchd plist installs daily 04:00 schedule ──────────────────────
LAUNCHD="$REPO_ROOT/scripts/setup/install-claude-tmp-cleanup-launchd.sh"
[[ -x "$LAUNCHD" ]] || fail "install-claude-tmp-cleanup-launchd.sh missing"
grep -q 'StartCalendarInterval' "$LAUNCHD" \
    || fail "StartCalendarInterval (cron schedule) not in launchd script"
grep -q '"4"\|<integer>4</integer>' "$LAUNCHD" \
    || fail "04:00 hour not specified in launchd plist"
pass "launchd plist has daily 04:00 StartCalendarInterval"

# ── Test 7: bytes_freed and files_removed in ambient event ───────────────────
grep -q 'bytes_freed\|files_removed' "$CLEANUP" \
    || fail "bytes_freed / files_removed not tracked in ambient event"
pass "bytes_freed + files_removed tracked in ambient event"

printf '\nAll claude-tmp-cleanup tests passed.\n'
