#!/usr/bin/env bash
# test-hardcoded-date-guard.sh — INFRA-971
#
# Tests:
#   1. code-structure: guard script exists + is executable
#   2. code-structure: guard is wired into pre-commit hook (section 15)
#   3. code-structure: bypass env var CHUMP_HARDCODED_DATE_CHECK referenced
#   4. logic: CHUMP_HARDCODED_DATE_CHECK=0 skips (exit 0) without repo
#   5. logic: added line with date in #[test] block → exit 1
#   6. logic: added line with date + time-bomb-ok bypass → exit 0
#   7. logic: date in non-test code → exit 0 (not flagged)
#   8. logic: date only in unmodified lines (not in diff) → exit 0
#   9. logic: non-src/*.rs file (scripts/) → exit 0 (not scanned)

set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# Use script path to find repo root — more reliable than git rev-parse in
# linked worktrees where --show-toplevel may return a stale path (INFRA-779).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/git-hooks/pre-commit-hardcoded-dates.sh"

echo "=== INFRA-971 hardcoded-date guard tests ==="
echo

# ── Tests 1-3: code-structure checks ─────────────────────────────────────────
echo "--- Test 1: guard script exists + is executable ---"
if [[ -x "$GUARD" ]]; then
    ok "guard exists and is executable"
else
    fail "guard NOT found or not executable at $GUARD"
fi

echo "--- Test 2: section 15 wired into pre-commit hook ---"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit"
if grep -q 'INFRA-971\|pre-commit-hardcoded-dates' "$HOOK"; then
    ok "section 15 (INFRA-971) present in pre-commit"
else
    fail "section 15 NOT found in pre-commit hook"
fi

echo "--- Test 3: bypass env var referenced in guard ---"
if grep -q 'CHUMP_HARDCODED_DATE_CHECK' "$GUARD"; then
    ok "CHUMP_HARDCODED_DATE_CHECK bypass present"
else
    fail "CHUMP_HARDCODED_DATE_CHECK NOT in guard script"
fi

# ── Tests 4-9: logic unit tests via a fake git repo ──────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

init_repo() {
    local dir="$1"
    git init -q "$dir"
    git -C "$dir" config user.email "ci@test.invalid"
    git -C "$dir" config user.name "CI"
    mkdir -p "$dir/src"
}

echo "--- Test 4: CHUMP_HARDCODED_DATE_CHECK=0 skips without a real repo ---"
set +e
out4=$(CHUMP_HARDCODED_DATE_CHECK=0 bash "$GUARD" 2>&1)
exit4=$?
set -e
if [[ "$exit4" -eq 0 ]]; then
    ok "bypass=0: exit 0"
else
    fail "bypass=0: expected exit 0, got $exit4"
fi

echo "--- Test 5: date in #[test] block in added line → exit 1 ---"
REPO5="$TMP/repo5"
init_repo "$REPO5"
# Create a base file and commit it
cat > "$REPO5/src/foo.rs" << 'RS'
fn helper() {}
RS
git -C "$REPO5" add src/foo.rs
CHUMP_GIT_IDENTITY_CHECK=0 CHUMP_GAPS_LOCK=0 CHUMP_EVENT_REGISTRY_CHECK=0 \
    git -C "$REPO5" commit -q -m "init" \
    --no-verify 2>/dev/null

# Now add a test with a hardcoded date
cat >> "$REPO5/src/foo.rs" << 'RS'

#[test]
fn my_test() {
    let ts = "2026-05-06T10:00:00Z";
    assert!(true);
}
RS
git -C "$REPO5" add src/foo.rs

set +e
out5=$(GIT_DIR="$REPO5/.git" GIT_WORK_TREE="$REPO5" bash "$GUARD" 2>&1)
exit5=$?
set -e
if [[ "$exit5" -ne 0 ]]; then
    ok "date-in-test: exit non-zero (blocked)"
else
    fail "date-in-test: expected non-zero exit, got 0"
fi
if echo "$out5" | grep -q "2026-05-06"; then
    ok "date-in-test: date literal in error message"
else
    fail "date-in-test: date NOT in error message; got: $out5"
fi

echo "--- Test 6: date + time-bomb-ok bypass → exit 0 ---"
REPO6="$TMP/repo6"
init_repo "$REPO6"
cat > "$REPO6/src/foo.rs" << 'RS'
fn helper() {}
RS
git -C "$REPO6" add src/foo.rs
CHUMP_GIT_IDENTITY_CHECK=0 CHUMP_GAPS_LOCK=0 CHUMP_EVENT_REGISTRY_CHECK=0 \
    git -C "$REPO6" commit -q -m "init" \
    --no-verify 2>/dev/null

cat >> "$REPO6/src/foo.rs" << 'RS'

#[test]
fn my_test() {
    let ts = "2026-05-06T10:00:00Z"; // chump-fmt: time-bomb-ok
    assert!(true);
}
RS
git -C "$REPO6" add src/foo.rs

set +e
GIT_DIR="$REPO6/.git" GIT_WORK_TREE="$REPO6" bash "$GUARD" 2>&1
exit6=$?
set -e
if [[ "$exit6" -eq 0 ]]; then
    ok "time-bomb-ok bypass: exit 0"
else
    fail "time-bomb-ok bypass: expected exit 0, got $exit6"
fi

echo "--- Test 7: date in non-test code → exit 0 ---"
REPO7="$TMP/repo7"
init_repo "$REPO7"
cat > "$REPO7/src/foo.rs" << 'RS'
fn helper() {}
RS
git -C "$REPO7" add src/foo.rs
CHUMP_GIT_IDENTITY_CHECK=0 CHUMP_GAPS_LOCK=0 CHUMP_EVENT_REGISTRY_CHECK=0 \
    git -C "$REPO7" commit -q -m "init" \
    --no-verify 2>/dev/null

# Date in non-test code — should not be flagged
cat >> "$REPO7/src/foo.rs" << 'RS'

fn format_date() -> &'static str {
    "2026-05-06T00:00:00Z"
}
RS
git -C "$REPO7" add src/foo.rs

set +e
GIT_DIR="$REPO7/.git" GIT_WORK_TREE="$REPO7" bash "$GUARD" 2>&1
exit7=$?
set -e
if [[ "$exit7" -eq 0 ]]; then
    ok "non-test date: exit 0 (not flagged)"
else
    fail "non-test date: expected exit 0, got $exit7"
fi

echo "--- Test 8: date only in unmodified lines (not in diff) → exit 0 ---"
REPO8="$TMP/repo8"
init_repo "$REPO8"
# Pre-commit the date — it's an existing line, not a new addition
cat > "$REPO8/src/foo.rs" << 'RS'
#[test]
fn existing_test() {
    let ts = "2026-05-06T10:00:00Z";
    assert!(true);
}
RS
git -C "$REPO8" add src/foo.rs
CHUMP_GIT_IDENTITY_CHECK=0 CHUMP_GAPS_LOCK=0 CHUMP_EVENT_REGISTRY_CHECK=0 \
    git -C "$REPO8" commit -q -m "init" \
    --no-verify 2>/dev/null

# Only add a new line that is clean
cat >> "$REPO8/src/foo.rs" << 'RS'

fn helper() {}
RS
git -C "$REPO8" add src/foo.rs

set +e
GIT_DIR="$REPO8/.git" GIT_WORK_TREE="$REPO8" bash "$GUARD" 2>&1
exit8=$?
set -e
if [[ "$exit8" -eq 0 ]]; then
    ok "pre-existing date: exit 0 (not in diff)"
else
    fail "pre-existing date: expected exit 0, got $exit8"
fi

echo "--- Test 9: non-src/*.rs file not scanned → exit 0 ---"
REPO9="$TMP/repo9"
init_repo "$REPO9"
cat > "$REPO9/src/foo.rs" << 'RS'
fn helper() {}
RS
git -C "$REPO9" add src/foo.rs
CHUMP_GIT_IDENTITY_CHECK=0 CHUMP_GAPS_LOCK=0 CHUMP_EVENT_REGISTRY_CHECK=0 \
    git -C "$REPO9" commit -q -m "init" \
    --no-verify 2>/dev/null

# Modify only a shell script (not src/*.rs)
mkdir -p "$REPO9/scripts"
cat > "$REPO9/scripts/check.sh" << 'SH'
# "2026-05-06" inside a test — in a shell script, not .rs
SH
git -C "$REPO9" add scripts/check.sh

set +e
GIT_DIR="$REPO9/.git" GIT_WORK_TREE="$REPO9" bash "$GUARD" 2>&1
exit9=$?
set -e
if [[ "$exit9" -eq 0 ]]; then
    ok "non-rs file: exit 0 (not scanned)"
else
    fail "non-rs file: expected exit 0, got $exit9"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
