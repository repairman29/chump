#!/usr/bin/env bash
# test-post-rebase-verify.sh — INFRA-1526
#
# Validates post-rebase-verify.sh detects silently-dropped hunks.
#
# Each test builds a real two-branch git repo:
#   main: base → main-advance (unrelated file)
#   feature: base → big-feature-commit
#   rebased: feature content replayed onto main-advance tip
# post-rebase-verify.sh is called with:
#   --base      = main-advance SHA (the new main tip after rebase)
#   --orig-head = feature-commit SHA (branch tip before rebase)
#
# Tests:
#  1. Clean rebase (feature content preserved) → exits 0, no events
#  2. Hunk drop (>50 lines gone after rebase) → exits 1, event emitted
#  3. Small drop (≤50 lines, below threshold) → exits 0, no events
#  4. File preserved across rebase → exits 0
#  5. Missing ORIG_HEAD → exits 2

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
VERIFY="$REPO_ROOT/scripts/coord/post-rebase-verify.sh"

PASS=0
FAIL=0
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

echo "=== INFRA-1526 post-rebase-verify test ==="
echo

if [[ ! -x "$VERIFY" ]]; then
    fail "scripts/coord/post-rebase-verify.sh not found or not executable"
    echo "FAIL — $FAIL failure(s)"
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Repo builder ──────────────────────────────────────────────────────────────
# Sets up a branching scenario and returns SHAs via named variables:
#   MAIN_TIP  = main-advance commit (base for rebase)
#   ORIG_TIP  = feature commit (branch before rebase)
#   REBASED_TIP = simulated rebase result (feature content on main-advance)
#
# $1 = repo dir
# $2 = feature file name
# $3 = feature content (what the feature branch added)
# $4 = rebased content (what appeared in rebased commit — may be empty for drop)
# Globals set: MAIN_TIP ORIG_TIP REBASED_TIP
setup_repo() {
    local dir="$1" feat_file="$2" feat_content="$3" rebased_content="$4"

    git -C "$dir" init -q
    git -C "$dir" config user.email "test@test"
    git -C "$dir" config user.name "Test"

    # base commit on main
    printf 'fn base() {}\n' > "$dir/base.rs"
    git -C "$dir" add base.rs
    git -C "$dir" commit -q -m "base"
    local base_sha
    base_sha="$(git -C "$dir" rev-parse HEAD)"

    # feature branch: fork from base, add large block
    git -C "$dir" checkout -q -b feature
    printf '%s' "$feat_content" > "$dir/$feat_file"
    git -C "$dir" add "$feat_file"
    git -C "$dir" commit -q -m "feature: add $feat_file"
    ORIG_TIP="$(git -C "$dir" rev-parse HEAD)"

    # main advances: add unrelated file
    git -C "$dir" checkout -q main
    printf 'fn from_main() {}\n' > "$dir/from_main.rs"
    git -C "$dir" add from_main.rs
    git -C "$dir" commit -q -m "main: advance"
    MAIN_TIP="$(git -C "$dir" rev-parse HEAD)"

    # rebased: feature content replayed on main tip
    if [[ -n "$rebased_content" ]]; then
        printf '%s' "$rebased_content" > "$dir/$feat_file"
        git -C "$dir" add "$feat_file"
    else
        # simulate drop: file present in feature but absent in rebased result
        git -C "$dir" rm -q --ignore-unmatch "$feat_file" 2>/dev/null || true
        printf 'fn base() {}\n' > "$dir/base.rs"
        git -C "$dir" add base.rs
    fi
    git -C "$dir" commit -q -m "rebased: $feat_file onto main"
    REBASED_TIP="$(git -C "$dir" rev-parse HEAD)"
}

# ── Helper vars (set by setup_repo) ───────────────────────────────────────────
MAIN_TIP="" ORIG_TIP="" REBASED_TIP=""

# ── Generate large feature content (N lines) ─────────────────────────────────
big_content() {
    local n="$1" prefix="${2:-fn feature_fn_}"
    local out="fn base_unchanged() {}"$'\n'
    for i in $(seq 1 "$n"); do out+="${prefix}${i}() {}"$'\n'; done
    printf '%s' "$out"
}

# ── Test 1: clean rebase (feature content preserved) ─────────────────────────
echo "--- Test 1: clean rebase (no drops) ---"
R1="$TMP/repo1"
mkdir "$R1"
FEAT="$(big_content 60)"
setup_repo "$R1" "feature.rs" "$FEAT" "$FEAT"

AMBIENT1="$TMP/ambient1.jsonl"; touch "$AMBIENT1"
rc=0
CHUMP_REPO_ROOT="$R1" CHUMP_AMBIENT_LOG="$AMBIENT1" \
    bash "$VERIFY" --base "$MAIN_TIP" --orig-head "$ORIG_TIP" || rc=$?
if [[ "$rc" -eq 0 ]]; then
    ok "Test 1: clean rebase exits 0"
else
    fail "Test 1: clean rebase exited $rc (expected 0)"
fi
if grep -q "rebase_hunk_dropped" "$AMBIENT1" 2>/dev/null; then
    fail "Test 1: unexpected rebase_hunk_dropped event"
else
    ok "Test 1: no rebase_hunk_dropped event"
fi

# ── Test 2: hunk drop detected (>50 lines gone after rebase) ──────────────────
echo "--- Test 2: hunk drop detected ---"
R2="$TMP/repo2"
mkdir "$R2"
FEAT2="$(big_content 80 "pub fn handler_")"
# rebased content: only the base line, 80 added lines are gone
setup_repo "$R2" "handlers.rs" "$FEAT2" ""

AMBIENT2="$TMP/ambient2.jsonl"; touch "$AMBIENT2"
rc=0
CHUMP_REPO_ROOT="$R2" CHUMP_AMBIENT_LOG="$AMBIENT2" \
    bash "$VERIFY" --base "$MAIN_TIP" --orig-head "$ORIG_TIP" || rc=$?
if [[ "$rc" -eq 1 ]]; then
    ok "Test 2: hunk drop exits 1"
else
    fail "Test 2: hunk drop exited $rc (expected 1)"
fi
if grep -q "rebase_hunk_dropped" "$AMBIENT2" 2>/dev/null; then
    ok "Test 2: rebase_hunk_dropped event emitted"
    event="$(grep "rebase_hunk_dropped" "$AMBIENT2" | head -1)"
    for field in ts kind file lines_dropped original_commit rebased_commit; do
        if printf '%s' "$event" | grep -q "\"$field\""; then
            ok "Test 2: event has field '$field'"
        else
            fail "Test 2: event missing field '$field'"
        fi
    done
else
    fail "Test 2: no rebase_hunk_dropped event (expected one)"
fi

# ── Test 3: small drop below threshold → no alarm ─────────────────────────────
echo "--- Test 3: small drop (≤50 lines, below threshold) ---"
R3="$TMP/repo3"
mkdir "$R3"
FEAT3="$(big_content 20 "fn small_fn_")"
# drop the file entirely — but only 20 lines so below threshold
setup_repo "$R3" "small.rs" "$FEAT3" ""

AMBIENT3="$TMP/ambient3.jsonl"; touch "$AMBIENT3"
rc=0
CHUMP_REPO_ROOT="$R3" CHUMP_AMBIENT_LOG="$AMBIENT3" \
    bash "$VERIFY" --base "$MAIN_TIP" --orig-head "$ORIG_TIP" || rc=$?
if [[ "$rc" -eq 0 ]]; then
    ok "Test 3: small drop (below threshold) exits 0"
else
    fail "Test 3: small drop exited $rc (expected 0)"
fi
if grep -q "rebase_hunk_dropped" "$AMBIENT3" 2>/dev/null; then
    fail "Test 3: unexpected rebase_hunk_dropped for below-threshold drop"
else
    ok "Test 3: no rebase_hunk_dropped for below-threshold drop"
fi

# ── Test 4: file with 60 lines preserved → exits 0 ────────────────────────────
echo "--- Test 4: file preserved across rebase ---"
R4="$TMP/repo4"
mkdir "$R4"
FEAT4="$(big_content 60 "fn route_")"
# rebased: same feature content (preserved)
setup_repo "$R4" "routes.rs" "$FEAT4" "$FEAT4"

AMBIENT4="$TMP/ambient4.jsonl"; touch "$AMBIENT4"
rc=0
CHUMP_REPO_ROOT="$R4" CHUMP_AMBIENT_LOG="$AMBIENT4" \
    bash "$VERIFY" --base "$MAIN_TIP" --orig-head "$ORIG_TIP" || rc=$?
if [[ "$rc" -eq 0 ]]; then
    ok "Test 4: preserved file exits 0"
else
    fail "Test 4: preserved file exited $rc (expected 0)"
fi
if grep -q "rebase_hunk_dropped" "$AMBIENT4" 2>/dev/null; then
    fail "Test 4: unexpected rebase_hunk_dropped for preserved file"
else
    ok "Test 4: no rebase_hunk_dropped for preserved file"
fi

# ── Test 5: missing ORIG_HEAD → exits 2 ───────────────────────────────────────
echo "--- Test 5: missing ORIG_HEAD ---"
R5="$TMP/repo5"
mkdir "$R5"
git -C "$R5" init -q
git -C "$R5" config user.email "t@t" && git -C "$R5" config user.name "T"
printf 'fn x() {}\n' > "$R5/x.rs"
git -C "$R5" add x.rs
git -C "$R5" commit -q -m "init"

AMBIENT5="$TMP/ambient5.jsonl"; touch "$AMBIENT5"
rc=0
CHUMP_REPO_ROOT="$R5" CHUMP_AMBIENT_LOG="$AMBIENT5" \
    bash "$VERIFY" 2>/dev/null || rc=$?
if [[ "$rc" -eq 2 ]]; then
    ok "Test 5: missing ORIG_HEAD exits 2"
else
    fail "Test 5: missing ORIG_HEAD exited $rc (expected 2)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
