#!/usr/bin/env bash
# test-obs-coverage-guard.sh — INFRA-757
#
# Tests scripts/ci/test-observability-coverage.sh against synthetic
# git-repo fixtures.
#
# Acceptance criteria verified:
#   (1) New scripts/dispatch/foo.sh with NO obs → REJECTED
#   (2) New scripts/dispatch/foo.sh with tracing::info!() → ACCEPTED
#   (3) New scripts/dispatch/foo.sh with a registered ambient kind literal → ACCEPTED
#   (4) New src/foo.rs not referenced from main.rs/dispatch.rs/agent_loop
#       → IGNORED (out of scope)
#   (5) New src/foo.rs referenced via `mod foo;` in main.rs with NO obs
#       → REJECTED
#   (6) New src/agent_loop/sub.rs with NO obs → REJECTED
#   (7) CHUMP_OBS_COVERAGE_CHECK=0 → ACCEPTED regardless

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-757 obs-coverage CI test fixture ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COVERAGE_TEST="$REPO_ROOT/scripts/ci/test-observability-coverage.sh"

if [ ! -x "$COVERAGE_TEST" ]; then
    echo "FATAL: $COVERAGE_TEST not found or not executable"
    exit 2
fi

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Build a fresh fake repo with the dispatch/main/agent_loop scaffolding.
seed_repo() {
    local repo=$1
    rm -rf "$repo"
    mkdir -p "$repo/src/agent_loop" "$repo/scripts/dispatch" "$repo/scripts/coord"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"

    cat > "$repo/src/main.rs" <<'RS'
mod dispatch;
mod existing;
fn main() {}
RS
    cat > "$repo/src/dispatch.rs" <<'RS'
pub fn dispatch() { tracing::info!("baseline"); }
RS
    cat > "$repo/src/existing.rs" <<'RS'
pub fn existing() { tracing::info!("baseline"); }
RS
    cat > "$repo/src/agent_loop/mod.rs" <<'RS'
pub mod base;
RS
    cat > "$repo/src/agent_loop/base.rs" <<'RS'
pub fn base() { tracing::info!("baseline"); }
RS
    git -C "$repo" add .
    git -C "$repo" commit -q -m "seed"
    # Simulate origin/main.
    git -C "$repo" update-ref refs/remotes/origin/main HEAD
}

# Run the coverage test inside the fake repo with no GITHUB_BASE_REF
# (it falls back to origin/main).
run_coverage() {
    local repo=$1
    cd "$repo" || return 2
    OUT=$("$COVERAGE_TEST" 2>&1)
    RC=$?
    cd - >/dev/null || true
    echo "$OUT"
    return $RC
}

# ── Test 1: dispatch script with no obs → rejected ──────────────────────────
echo "--- Test 1: new scripts/dispatch/foo.sh with no obs → REJECTED ---"
REPO="$TMPDIR_BASE/t1"
seed_repo "$REPO"
cat > "$REPO/scripts/dispatch/foo.sh" <<'SH'
#!/bin/bash
echo "did the thing"
SH
git -C "$REPO" add scripts/dispatch/foo.sh
git -C "$REPO" commit -q -m "add dispatch foo with no obs"
OUT=$(run_coverage "$REPO" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "scripts/dispatch/foo.sh"; then
    ok "dispatch script with no obs is rejected"
else
    fail "dispatch script with no obs should be rejected (rc=$RC, out=$OUT)"
fi

# ── Test 2: dispatch script with tracing → accepted ─────────────────────────
echo "--- Test 2: new dispatch script with tracing::info → ACCEPTED ---"
REPO="$TMPDIR_BASE/t2"
seed_repo "$REPO"
cat > "$REPO/scripts/dispatch/foo.sh" <<'SH'
#!/bin/bash
# tracing::info!("hello from a comment, but still counts as a marker")
echo "{\"kind\":\"foo_event\"}"
SH
git -C "$REPO" add scripts/dispatch/foo.sh
git -C "$REPO" commit -q -m "add dispatch foo"
if run_coverage "$REPO" >/dev/null 2>&1; then
    ok "dispatch script with kind literal accepted"
else
    fail "dispatch script with kind literal should be accepted"
fi

# ── Test 3: dispatch script with kind literal → accepted ───────────────────
echo "--- Test 3: new dispatch script with kind literal → ACCEPTED ---"
REPO="$TMPDIR_BASE/t3"
seed_repo "$REPO"
cat > "$REPO/scripts/dispatch/foo.sh" <<'SH'
#!/bin/bash
printf '{"kind":"obs_coverage_test_fixture","ts":"now"}\n'
SH
git -C "$REPO" add scripts/dispatch/foo.sh
git -C "$REPO" commit -q -m "add dispatch foo with kind"
if run_coverage "$REPO" >/dev/null 2>&1; then
    ok "dispatch script with kind literal accepted"
else
    fail "dispatch script with kind literal should be accepted"
fi

# ── Test 4: src/foo.rs not referenced anywhere → ignored ────────────────────
echo "--- Test 4: orphan src/foo.rs not referenced → IGNORED (out of scope) ---"
REPO="$TMPDIR_BASE/t4"
seed_repo "$REPO"
cat > "$REPO/src/orphan.rs" <<'RS'
pub fn orphan() { println!("nothing logs"); }
RS
git -C "$REPO" add src/orphan.rs
git -C "$REPO" commit -q -m "add orphan rs"
if run_coverage "$REPO" >/dev/null 2>&1; then
    ok "orphan src/*.rs is ignored"
else
    fail "orphan src/*.rs should be ignored (out of scope)"
fi

# ── Test 5: src/foo.rs referenced via `mod foo;` with no obs → rejected ─────
echo "--- Test 5: src/wired.rs referenced via mod with no obs → REJECTED ---"
REPO="$TMPDIR_BASE/t5"
seed_repo "$REPO"
# Update main.rs to add a reference. Need to commit BEFORE the file we
# want graded so it's part of "modified" not "added", AND add a new
# module file with no obs.
sed -i.bak 's|mod existing;|mod existing;\nmod wired;|' "$REPO/src/main.rs"
rm "$REPO/src/main.rs.bak"
cat > "$REPO/src/wired.rs" <<'RS'
pub fn wired() { println!("no observability"); }
RS
git -C "$REPO" add src/main.rs src/wired.rs
git -C "$REPO" commit -q -m "wire wired.rs in main without obs"
OUT=$(run_coverage "$REPO" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "src/wired.rs"; then
    ok "wired src/*.rs with no obs is rejected"
else
    fail "wired src/*.rs with no obs should be rejected (rc=$RC, out=$OUT)"
fi

# ── Test 6: new src/agent_loop/sub.rs with no obs → rejected ────────────────
echo "--- Test 6: new src/agent_loop/sub.rs with no obs → REJECTED ---"
REPO="$TMPDIR_BASE/t6"
seed_repo "$REPO"
cat > "$REPO/src/agent_loop/sub.rs" <<'RS'
pub fn sub() { println!("no logs here"); }
RS
git -C "$REPO" add src/agent_loop/sub.rs
git -C "$REPO" commit -q -m "add sub agent_loop"
OUT=$(run_coverage "$REPO" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "src/agent_loop/sub.rs"; then
    ok "agent_loop submodule with no obs rejected"
else
    fail "agent_loop submodule with no obs should be rejected (rc=$RC, out=$OUT)"
fi

# ── Test 7: bypass env var → accepted ───────────────────────────────────────
echo "--- Test 7: CHUMP_OBS_COVERAGE_CHECK=0 → ACCEPTED ---"
REPO="$TMPDIR_BASE/t7"
seed_repo "$REPO"
cat > "$REPO/scripts/dispatch/foo.sh" <<'SH'
#!/bin/bash
echo "no obs"
SH
git -C "$REPO" add scripts/dispatch/foo.sh
git -C "$REPO" commit -q -m "no obs"
if CHUMP_OBS_COVERAGE_CHECK=0 run_coverage "$REPO" >/dev/null 2>&1; then
    ok "bypass env accepts"
else
    fail "bypass env should accept"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
