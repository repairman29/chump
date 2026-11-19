#!/usr/bin/env bash
# scripts/ci/test-chump-rebase-and-push.sh — INFRA-1404
#
# Verifies scripts/coord/chump-rebase-and-push.sh:
#   1. Detects branch (refuses to run on main)
#   2. Detects dirty working tree and exits 1
#   3. Cleans rebase: divergent branch rebases onto "main", push succeeds → exit 0
#   4. Conflict path: exits 2 when rebase hits unresolvable conflict
#   5. Emits kind=rebase_and_push_invoked to ambient.jsonl on success
#   6. Dry-run mode: prints commands, does NOT push
#   7. Static: script guards and exit-code contract
#
# Strategy: uses local bare repos as fake remotes (no network I/O).
# CHUMP_REPO_ROOT overrides script's git root to target the test repo.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RAP="${REPO_ROOT}/scripts/coord/chump-rebase-and-push.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; FAILS=()
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

[[ -f "$RAP" ]] || { echo "FAIL: $RAP not found"; exit 2; }
bash -n "$RAP" || { echo "FAIL: $RAP has syntax errors"; exit 2; }

echo "=== INFRA-1404 chump-rebase-and-push tests ==="
echo

# ── Shared: create a fake remote + worktree with feature branch ───────────────
# Returns the worktree path via stdout.
_setup_repos() {
    local label="$1"
    local base="$TMP/$label"
    mkdir -p "$base"

    # Bare remote
    git init --bare "$base/remote.git" -q 2>/dev/null

    # Bootstrap main in the bare repo via a temp clone
    local init="$base/init"
    git clone "$base/remote.git" "$init" -q 2>/dev/null
    git -C "$init" config user.email "test@chump.local"
    git -C "$init" config user.name "Test"
    echo "base" > "$init/base.txt"
    git -C "$init" add base.txt
    git -C "$init" commit -m "base" -q
    git -C "$init" push origin HEAD:main -q 2>/dev/null

    # Feature branch: starts from main, adds one commit
    git -C "$init" checkout -b feature -q 2>/dev/null
    echo "feature work" > "$init/feature.txt"
    git -C "$init" add feature.txt
    git -C "$init" commit -m "feature" -q
    git -C "$init" push origin feature -q 2>/dev/null

    # Advance main on remote (simulates sibling merging something while feature ran)
    git -C "$init" checkout main -q 2>/dev/null
    echo "sibling change" >> "$init/base.txt"
    git -C "$init" add base.txt
    git -C "$init" commit -m "sibling commit on main" -q
    git -C "$init" push origin main -q 2>/dev/null

    # Create the actual work clone: tracks origin/feature
    local work="$base/work"
    git clone "$base/remote.git" "$work" -q 2>/dev/null
    git -C "$work" config user.email "test@chump.local"
    git -C "$work" config user.name "Test"
    git -C "$work" checkout -b feature --track origin/feature -q 2>/dev/null

    # Set up .chump-locks for ambient writes
    mkdir -p "$work/.chump-locks"

    echo "$work"
}

# ── Test 1: refuses to run on main ───────────────────────────────────────────
echo "[1. Refuses to run on main branch]"
W1="$(_setup_repos t1)"
git -C "$W1" checkout main -q 2>/dev/null
set +e
CHUMP_REPO_ROOT="$W1" \
CHUMP_AMBIENT_LOG="$TMP/amb1.jsonl" \
    bash "$RAP" main --remote origin 2>/dev/null
rc=$?
set -e
if [[ "$rc" -eq 1 ]]; then
    ok "exits 1 when run on main branch"
else
    fail "expected exit 1 on main branch, got $rc"
fi

# ── Test 2: refuses dirty working tree ───────────────────────────────────────
echo
echo "[2. Refuses dirty working tree]"
W2="$(_setup_repos t2)"
echo "dirty" >> "$W2/base.txt"  # modify a tracked file (untracked files aren't caught by git diff)
set +e
CHUMP_REPO_ROOT="$W2" \
CHUMP_AMBIENT_LOG="$TMP/amb2.jsonl" \
    bash "$RAP" main --remote origin 2>/dev/null
rc=$?
set -e
git -C "$W2" checkout -- base.txt 2>/dev/null || true  # restore tracked file
if [[ "$rc" -eq 1 ]]; then
    ok "exits 1 with uncommitted changes"
else
    fail "expected exit 1 with dirty tree, got $rc"
fi

# ── Test 3: clean rebase + push succeeds ─────────────────────────────────────
echo
echo "[3. Clean rebase onto main and push (exit 0)]"
W3="$(_setup_repos t3)"
AMB3="$TMP/amb3.jsonl"
touch "$AMB3"
set +e
CHUMP_REPO_ROOT="$W3" \
CHUMP_AMBIENT_LOG="$AMB3" \
    bash "$RAP" main --remote origin 2>/dev/null
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
    ok "clean rebase+push exits 0"
else
    fail "clean rebase+push expected exit 0, got $rc"
fi

# Check ambient event
if grep -q '"kind":"rebase_and_push_invoked"' "$AMB3" 2>/dev/null; then
    ok "kind=rebase_and_push_invoked emitted to ambient.jsonl"
else
    fail "kind=rebase_and_push_invoked NOT emitted to ambient.jsonl"
fi

if grep '"kind":"rebase_and_push_invoked"' "$AMB3" 2>/dev/null | grep -q '"branch":"feature"'; then
    ok "ambient event contains branch=feature"
else
    fail "ambient event missing branch=feature"
fi

if grep '"kind":"rebase_and_push_invoked"' "$AMB3" 2>/dev/null | grep -q '"retries":0'; then
    ok "ambient event shows retries=0"
else
    fail "ambient event missing retries=0"
fi

# ── Test 4: conflict → exit 2 ────────────────────────────────────────────────
echo
echo "[4. Unresolvable conflict exits 2]"
W4="$(_setup_repos t4)"
AMB4="$TMP/amb4.jsonl"
touch "$AMB4"

# Create a conflicting change on main that overlaps with feature.txt
local_init="$TMP/t4/init"
git -C "$local_init" checkout main -q 2>/dev/null
echo "main version conflicts with feature" > "$local_init/feature.txt"
git -C "$local_init" add feature.txt
git -C "$local_init" commit -m "main also touches feature.txt" -q
git -C "$local_init" push origin main -q 2>/dev/null

set +e
CHUMP_REPO_ROOT="$W4" \
CHUMP_AMBIENT_LOG="$AMB4" \
    bash "$RAP" main --remote origin --no-merge-driver 2>/dev/null
rc=$?
set -e
if [[ "$rc" -eq 2 ]]; then
    ok "conflict exits 2"
else
    fail "conflict expected exit 2, got $rc"
fi

# Working tree should be clean after abort (rebase --abort was called)
wt_status="$(git -C "$W4" status --short 2>/dev/null || echo '?')"
if [[ -z "$wt_status" ]]; then
    ok "working tree clean after conflict abort"
else
    fail "working tree dirty after conflict abort: $wt_status"
fi

# ── Test 5: dry-run does not push ────────────────────────────────────────────
echo
echo "[5. Dry-run skips actual push]"
W5="$(_setup_repos t5)"
before_sha="$(git -C "$W5" rev-parse origin/feature 2>/dev/null || echo 'unknown')"
set +e
CHUMP_REPO_ROOT="$W5" \
CHUMP_AMBIENT_LOG="$TMP/amb5.jsonl" \
    bash "$RAP" main --remote origin --dry-run 2>/dev/null
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
    ok "dry-run exits 0"
else
    fail "dry-run expected exit 0, got $rc"
fi

after_sha="$(git -C "$W5" rev-parse origin/feature 2>/dev/null || echo 'unknown')"
if [[ "$before_sha" == "$after_sha" ]]; then
    ok "dry-run: remote SHA unchanged (no push occurred)"
else
    fail "dry-run: remote SHA changed ($before_sha → $after_sha)"
fi

# ── Test 6: static guards ────────────────────────────────────────────────────
echo
echo "[6. Static: exit-code contract and ambient emit]"

if grep -q "exit 2" "$RAP"; then
    ok "script uses exit 2 for conflict path"
else
    fail "script missing exit 2 for conflict path"
fi

if grep -q "exit 3" "$RAP"; then
    ok "script uses exit 3 for push-retry exhausted"
else
    fail "script missing exit 3 for push-retry exhausted"
fi

if grep -q "GIT_SEQUENCE_EDITOR" "$RAP"; then
    ok "non-interactive mode uses GIT_SEQUENCE_EDITOR"
else
    fail "missing GIT_SEQUENCE_EDITOR for non-interactive rebase"
fi

if grep -q "rebase_and_push_invoked" "$RAP"; then
    ok "script emits kind=rebase_and_push_invoked"
else
    fail "script missing kind=rebase_and_push_invoked ambient emit"
fi

if grep -q "CHUMP_REPO_ROOT" "$RAP"; then
    ok "CHUMP_REPO_ROOT override supported for hermetic test isolation"
else
    fail "CHUMP_REPO_ROOT override missing — test isolation impossible"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  ✗ %s\n' "$f"; done
    exit 1
fi
echo "PASS"
