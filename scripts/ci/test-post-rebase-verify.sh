#!/usr/bin/env bash
# test-post-rebase-verify.sh — INFRA-1526
#
# Smoke-tests for scripts/ci/post-rebase-verify.sh:
#   1. Clean rebase (no drops) → exit 0.
#   2. File below threshold (40 lines) → exit 0 (ignored).
#   3. File with >50 original lines that disappears after rebase → exit 1 + ambient event.
#   4. ORIG_HEAD absent → exit 0 (skip gracefully).
#   5. Multiple dropped files → exit 1, correct event count.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ci/post-rebase-verify.sh"

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── helpers ──────────────────────────────────────────────────────────────────

init_git_repo() {
    local dir="$1"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@chump"
    git -C "$dir" config user.name "Test"
    git -C "$dir" commit --allow-empty -m "root" -q
}

make_file_with_lines() {
    local dir="$1" file="$2" n="$3"
    python3 -c "print('\n'.join(['line%d' % i for i in range($n)]))" > "$dir/$file"
}

# run_verify <repo_dir> <ambient_log> <base_sha> [extra env vars...]
# Runs post-rebase-verify.sh against the given temp repo via REBASE_VERIFY_REPO_ROOT.
run_verify() {
    local repo="$1" amb="$2" base="$3"
    shift 3
    REBASE_VERIFY_REPO_ROOT="$repo" \
        CHUMP_AMBIENT_LOG="$amb" \
        REBASE_VERIFY_BASE="$base" \
        "$@" \
        bash "$SCRIPT"
}

# ── Test 1: No drops → exit 0 ────────────────────────────────────────────────
REPO="$TMP/repo1"
mkdir "$REPO"
init_git_repo "$REPO"
BASE_SHA=$(git -C "$REPO" rev-parse HEAD)

make_file_with_lines "$REPO" "foo.rs" 80
git -C "$REPO" add foo.rs
git -C "$REPO" commit -m "feat: 80 lines" -q
ORIG_SHA=$(git -C "$REPO" rev-parse HEAD)

# Simulate no-drop rebase: ORIG_HEAD = HEAD (nothing changed).
echo "$ORIG_SHA" > "$REPO/.git/ORIG_HEAD"

AMB1="$TMP/amb1.jsonl"
run_verify "$REPO" "$AMB1" "$BASE_SHA" \
    || fail "Test 1: expected exit 0 (no drops), got non-zero"

[[ ! -f "$AMB1" ]] || [[ $(wc -l < "$AMB1") -eq 0 ]] \
    || fail "Test 1: unexpected ambient events"
ok "Test 1: clean rebase → exit 0"

# ── Test 2: Below threshold (40 lines) → exit 0 ─────────────────────────────
REPO="$TMP/repo2"
mkdir "$REPO"
init_git_repo "$REPO"
BASE_SHA2=$(git -C "$REPO" rev-parse HEAD)

make_file_with_lines "$REPO" "small.rs" 40
git -C "$REPO" add small.rs
git -C "$REPO" commit -m "feat: 40 lines" -q
ORIG_SHA2=$(git -C "$REPO" rev-parse HEAD)

# Simulated rebase drops the file entirely (below threshold — should be ignored).
git -C "$REPO" rm small.rs -q
git -C "$REPO" commit -m "drop small.rs" -q

echo "$ORIG_SHA2" > "$REPO/.git/ORIG_HEAD"
AMB2="$TMP/amb2.jsonl"

run_verify "$REPO" "$AMB2" "$BASE_SHA2" \
    || fail "Test 2: expected exit 0 (below threshold), got non-zero"

[[ ! -f "$AMB2" ]] || [[ $(wc -l < "$AMB2") -eq 0 ]] \
    || fail "Test 2: unexpected ambient events for below-threshold file"
ok "Test 2: below-threshold file ignored → exit 0"

# ── Test 3: 80-line file disappears → exit 1, ambient event ─────────────────
REPO="$TMP/repo3"
mkdir "$REPO"
init_git_repo "$REPO"
BASE_SHA3=$(git -C "$REPO" rev-parse HEAD)

make_file_with_lines "$REPO" "big.rs" 80
git -C "$REPO" add big.rs
git -C "$REPO" commit -m "feat: 80-line block" -q
ORIG_SHA3=$(git -C "$REPO" rev-parse HEAD)

# Simulated post-rebase HEAD: big.rs was silently dropped.
git -C "$REPO" rm big.rs -q
git -C "$REPO" commit -m "post-rebase: big.rs dropped" -q

echo "$ORIG_SHA3" > "$REPO/.git/ORIG_HEAD"
AMB3="$TMP/amb3.jsonl"

run_verify "$REPO" "$AMB3" "$BASE_SHA3" \
    && fail "Test 3: expected exit 1 (drop detected), got exit 0"

[[ -f "$AMB3" ]] && grep -q '"kind":"rebase_hunk_dropped"' "$AMB3" \
    || fail "Test 3: no rebase_hunk_dropped event in ambient log"
grep -q '"file":"big.rs"' "$AMB3" \
    || fail "Test 3: event missing file field"
ok "Test 3: 80-line drop → exit 1 + ambient event"

# ── Test 4: ORIG_HEAD absent → exit 0 ───────────────────────────────────────
REPO="$TMP/repo4"
mkdir "$REPO"
init_git_repo "$REPO"
BASE_SHA4=$(git -C "$REPO" rev-parse HEAD)

# No ORIG_HEAD written.
AMB4="$TMP/amb4.jsonl"

run_verify "$REPO" "$AMB4" "$BASE_SHA4" \
    || fail "Test 4: expected exit 0 (no ORIG_HEAD), got non-zero"

ok "Test 4: no ORIG_HEAD → exit 0 (skip gracefully)"

# ── Test 5: Multiple dropped files → exit 1, two events ─────────────────────
REPO="$TMP/repo5"
mkdir "$REPO"
init_git_repo "$REPO"
BASE_SHA5=$(git -C "$REPO" rev-parse HEAD)

make_file_with_lines "$REPO" "alpha.rs" 60
make_file_with_lines "$REPO" "beta.rs" 70
git -C "$REPO" add alpha.rs beta.rs
git -C "$REPO" commit -m "feat: two big files" -q
ORIG_SHA5=$(git -C "$REPO" rev-parse HEAD)

# Simulated post-rebase: both files dropped.
git -C "$REPO" rm alpha.rs beta.rs -q
git -C "$REPO" commit -m "post-rebase: both dropped" -q

echo "$ORIG_SHA5" > "$REPO/.git/ORIG_HEAD"
AMB5="$TMP/amb5.jsonl"

run_verify "$REPO" "$AMB5" "$BASE_SHA5" \
    && fail "Test 5: expected exit 1 (two drops), got exit 0"

event_count=$(grep -c '"kind":"rebase_hunk_dropped"' "$AMB5" || true)
[[ "$event_count" -eq 2 ]] \
    || fail "Test 5: expected 2 events, got $event_count"
ok "Test 5: two dropped files → exit 1 + two ambient events"

echo ""
echo "All tests passed."
