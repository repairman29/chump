#!/usr/bin/env bash
# scripts/ci/test-bot-merge-already-claimed.sh — INFRA-1901
#
# bot-merge.sh used to unconditionally re-invoke `chump claim <gid>` even
# when already running from inside that gap's leased worktree, hitting the
# "worktree already exists" failure path. Baseline (2026-05-23): 3 of 4
# sub-agents (INFRA-1586, INFRA-1585, INFRA-1743) hit this and were forced
# into manual `gh pr create` + `gh pr merge --auto` fallback.
#
# This test exercises the core detection primitive directly —
# lease_pwd_in_leased_worktree() in scripts/lib/lease.sh, which bot-merge.sh
# calls before ever invoking `chump claim` — against a synthesized state.db
# lease row + matching worktree dir + feature branch with one commit. A
# full end-to-end bot-merge.sh run needs a live GitHub remote (gh pr
# create/merge) and is out of scope for a CI smoke test; the contract
# checks below confirm the wiring into bot-merge.sh's claim section.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
LEASE_LIB="$REPO_ROOT/scripts/lib/lease.sh"

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

command -v sqlite3 >/dev/null 2>&1 || { echo "[test-bot-merge-already-claimed] SKIP: sqlite3 not found"; exit 0; }

[[ -f "$LEASE_LIB" ]] || { fail "lease.sh not found at $LEASE_LIB"; echo "Passed: $PASS Failed: $FAIL"; exit 1; }
# shellcheck source=../lib/lease.sh
source "$LEASE_LIB"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

MAIN_REPO="$WORK_DIR/main-repo"
WORKTREE="$WORK_DIR/chump-infra-9901"
mkdir -p "$MAIN_REPO"

# ── Synthesize: a git repo, a feature branch worktree with one commit ──────
git init -q "$MAIN_REPO"
git -C "$MAIN_REPO" config user.email "test@example.com"
git -C "$MAIN_REPO" config user.name "Test"
echo "hello" > "$MAIN_REPO/README.md"
git -C "$MAIN_REPO" add README.md
git -C "$MAIN_REPO" commit -q -m "init"
git -C "$MAIN_REPO" branch chump/infra-9901-claim
git -C "$MAIN_REPO" worktree add -q "$WORKTREE" chump/infra-9901-claim
echo "gap work" > "$WORKTREE/feature.txt"
git -C "$WORKTREE" add feature.txt
git -C "$WORKTREE" -c user.email=test@example.com -c user.name=Test commit -q -m "INFRA-9901: feature work"

# ── Synthesize: state.db leases row pointing at that worktree ──────────────
mkdir -p "$MAIN_REPO/.chump"
STATE_DB="$MAIN_REPO/.chump/state.db"
sqlite3 "$STATE_DB" "
CREATE TABLE leases (
    session_id  TEXT PRIMARY KEY,
    gap_id      TEXT NOT NULL,
    worktree    TEXT NOT NULL DEFAULT '',
    expires_at  INTEGER NOT NULL
);
INSERT INTO leases VALUES ('claim-infra-9901-1-1', 'INFRA-9901', '$WORKTREE', 9999999999);
"

# ── Test 1: pwd inside the leased worktree — detection fires ───────────────
if (cd "$WORKTREE" && lease_pwd_in_leased_worktree "INFRA-9901" "$STATE_DB"); then
    pass "detects pwd inside the leased worktree"
else
    fail "did not detect pwd inside the leased worktree"
fi

# ── Test 2: a subdirectory of the leased worktree also matches ─────────────
mkdir -p "$WORKTREE/src"
if (cd "$WORKTREE/src" && lease_pwd_in_leased_worktree "INFRA-9901" "$STATE_DB"); then
    pass "detects a subdirectory of the leased worktree"
else
    fail "did not detect a subdirectory of the leased worktree"
fi

# ── Test 3: pwd outside the leased worktree — no false positive ────────────
OUTSIDE="$WORK_DIR/somewhere-else"
mkdir -p "$OUTSIDE"
if (cd "$OUTSIDE" && lease_pwd_in_leased_worktree "INFRA-9901" "$STATE_DB"); then
    fail "false positive: matched pwd outside the leased worktree"
else
    pass "correctly does not match pwd outside the leased worktree"
fi

# ── Test 4: no lease row for the gap — returns false, not an error ─────────
if (cd "$WORKTREE" && lease_pwd_in_leased_worktree "INFRA-NOPE" "$STATE_DB"); then
    fail "false positive: matched a gap with no lease row"
else
    pass "correctly returns false when no lease row exists"
fi

# ── Test 5: explicit pwd arg (no subshell cd needed) works the same way ────
if lease_pwd_in_leased_worktree "INFRA-9901" "$STATE_DB" "$WORKTREE/src"; then
    pass "explicit pwd arg form matches subdirectory"
else
    fail "explicit pwd arg form failed to match subdirectory"
fi

# ── Contract checks: bot-merge.sh wires the primitive in before chump claim ─
[[ -f "$BOT_MERGE" ]] || { fail "bot-merge.sh not found at $BOT_MERGE"; echo "Passed: $PASS Failed: $FAIL"; exit 1; }

assert_bm() {
    local desc="$1" pattern="$2"
    if grep -qE "$pattern" "$BOT_MERGE"; then
        pass "$desc"
    else
        fail "$desc (pattern: $pattern)"
    fi
}

assert_bm "bot-merge sources scripts/lib/lease.sh" \
    'source "\$\(dirname "\$0"\)/\.\./lib/lease\.sh"'

assert_bm "claim section checks lease_pwd_in_leased_worktree before chump claim" \
    'lease_pwd_in_leased_worktree'

assert_bm "CHUMP_BOT_MERGE_SKIP_CLAIM bypass is wired" \
    'CHUMP_BOT_MERGE_SKIP_CLAIM'

assert_bm "bypass emits kind=bot_merge_skip_claim_lax" \
    'bot_merge_skip_claim_lax'

assert_bm "skip-claim guards the chump claim invocation itself" \
    '_skip_claim.*-eq 1'

if bash -n "$BOT_MERGE" 2>/dev/null; then
    pass "bash -n bot-merge.sh — syntax clean"
else
    fail "bash -n bot-merge.sh — syntax error introduced"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
