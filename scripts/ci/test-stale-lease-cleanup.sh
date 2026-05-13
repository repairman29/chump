#!/usr/bin/env bash
# CI: INFRA-1017 — stale state.db lease cleanup
#
# Verifies:
#   1. bot-merge.sh _bm_cleanup contains state.db DELETE on abnormal exit
#   2. stale-gap-lock-reaper.sh sweeps expired state.db leases rows
#   3. stale-gap-lock-reaper.sh sweeps rows whose worktree no longer exists
set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BM="${REPO_ROOT}/scripts/coord/bot-merge.sh"
REAPER="${REPO_ROOT}/scripts/ops/stale-gap-lock-reaper.sh"

# ── Test 1: bot-merge.sh _bm_cleanup deletes leases row ─────────────────────
echo "Test 1: bot-merge.sh _bm_cleanup references state.db leases DELETE"
if grep -q 'DELETE FROM leases WHERE session_id' "$BM"; then
    ok "_bm_cleanup contains DELETE FROM leases WHERE session_id"
else
    fail "_bm_cleanup missing state.db leases DELETE (INFRA-1017)"
fi

# ── Test 2: stale-gap-lock-reaper sweeps expired state.db leases ─────────────
echo "Test 2: stale-gap-lock-reaper.sh sweeps expired state.db leases"
if grep -q 'expires_at\|INFRA-1017' "$REAPER"; then
    ok "stale-gap-lock-reaper references expires_at sweep (INFRA-1017)"
else
    fail "stale-gap-lock-reaper missing expires_at sweep"
fi

# ── Test 3: reaper vacuums rows where worktree is gone ───────────────────────
echo "Test 3: stale-gap-lock-reaper.sh vacuums rows with missing worktree"
if grep -q 'worktree_gone\|! -d.*worktree' "$REAPER"; then
    ok "stale-gap-lock-reaper detects missing worktree"
else
    fail "stale-gap-lock-reaper missing worktree-gone detection"
fi

# ── Test 4: functional — expired lease is reaped ─────────────────────────────
echo "Test 4: functional reap of expired state.db lease"
TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT
FAKE_DB="${TMPDIR_T}/state.db"
FAKE_LOCKS="${TMPDIR_T}/locks"
mkdir -p "$FAKE_LOCKS"

# Create leases table and insert an expired row
sqlite3 "$FAKE_DB" "$(cat <<'SQL'
CREATE TABLE leases (
    session_id TEXT PRIMARY KEY,
    gap_id     TEXT NOT NULL,
    worktree   TEXT NOT NULL DEFAULT '',
    expires_at INTEGER NOT NULL
);
SQL
)"
# expired_at is in the past
PAST=$(( $(date +%s) - 3600 ))
sqlite3 "$FAKE_DB" "INSERT INTO leases VALUES ('dead-session','INFRA-999','/nonexistent/worktree',$PAST)"

# Run reaper in execute mode against our fake DB; use temp file to avoid SIGPIPE
REAPER_OUT="${TMPDIR_T}/reaper.out"
CHUMP_STATE_DB="$FAKE_DB" CHUMP_LOCK_DIR="$FAKE_LOCKS" \
    bash "$REAPER" --execute > "$REAPER_OUT" 2>&1 || true
COUNT_AFTER="$(sqlite3 "$FAKE_DB" 'SELECT count(*) FROM leases')"

if [[ "$COUNT_AFTER" -eq 0 ]] && grep -q 'REAPED state.db lease' "$REAPER_OUT"; then
    ok "expired lease reaped from state.db"
else
    fail "expired lease NOT reaped (rows remaining: $COUNT_AFTER, output: $(cat "$REAPER_OUT"))"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
