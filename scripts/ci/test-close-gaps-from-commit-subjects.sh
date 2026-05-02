#!/usr/bin/env bash
# test-close-gaps-from-commit-subjects.sh — INFRA-236 unit tests.
#
# Verifies the 5 acceptance scenarios from INFRA-236:
#   (1) Single-gap closure: "INFRA-XXX: ..." subject closes INFRA-XXX
#   (2) Multi-gap closure: "INFRA-XXX: ... + close INFRA-YYY" closes both
#   (3) Filing-PR safety: "chore(gaps): file INFRA-XXX" does NOT close
#   (4) Opt-out: "[no-close] INFRA-XXX: ..." does NOT close
#   (5) Idempotency: re-run on already-done gap is a no-op (no error, no edit)
#
# Run: ./scripts/ci/test-close-gaps-from-commit-subjects.sh
# Exits non-zero on any failure.

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-236 commit-subject-closure unit tests ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLOSER="$REPO_ROOT/scripts/coord/close-gaps-from-commit-subjects.sh"

if [ ! -x "$CLOSER" ]; then
    chmod +x "$CLOSER" 2>/dev/null || true
fi
if [ ! -x "$CLOSER" ]; then
    echo "FATAL: closer script not executable: $CLOSER"
    exit 2
fi

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

FAKE_REPO="$TMPDIR_BASE/repo"
mkdir -p "$FAKE_REPO/docs/gaps"
git -C "$FAKE_REPO" init -q -b main
git -C "$FAKE_REPO" config user.email "test@test.com"
git -C "$FAKE_REPO" config user.name "Test"

# Seed open gaps used across tests.
seed_gap() {
    local id="$1"
    cat > "$FAKE_REPO/docs/gaps/$id.yaml" <<YAML
- id: $id
  domain: infra
  title: test gap $id
  status: open
  priority: P1
  effort: xs
YAML
}

reset_repo() {
    git -C "$FAKE_REPO" reset -q --hard >/dev/null 2>&1 || true
    git -C "$FAKE_REPO" clean -fdq >/dev/null 2>&1 || true
    rm -rf "$FAKE_REPO/docs/gaps"
    mkdir -p "$FAKE_REPO/docs/gaps"
}

assert_status() {
    local id="$1" expected="$2" reason="$3"
    local actual
    actual=$(awk '/^[[:space:]]*status:/ {print $2; exit}' "$FAKE_REPO/docs/gaps/$id.yaml")
    if [ "$actual" = "$expected" ]; then
        ok "$reason: $id has status:$expected"
    else
        fail "$reason: $id expected status:$expected, got status:$actual"
    fi
}

assert_closed_pr() {
    local id="$1" expected="$2"
    local actual
    actual=$(awk '/^[[:space:]]*closed_pr:/ {print $2; exit}' "$FAKE_REPO/docs/gaps/$id.yaml")
    if [ "$actual" = "$expected" ]; then
        ok "  → $id closed_pr=$expected"
    else
        fail "  → $id expected closed_pr=$expected, got closed_pr=$actual"
    fi
}

# ── Test 1: single-gap closure ───────────────────────────────────────────────
echo "--- Test 1: single-gap closure ('INFRA-100: ...' closes INFRA-100) ---"
reset_repo
seed_gap "INFRA-100"
git -C "$FAKE_REPO" add . && git -C "$FAKE_REPO" commit -q -m "seed"
git -C "$FAKE_REPO" commit --allow-empty -q -m "INFRA-100: ship the thing"
( cd "$FAKE_REPO" && "$CLOSER" "HEAD~1..HEAD" 999 ) >/dev/null 2>&1 \
    || fail "closer exited non-zero on single-gap"
assert_status "INFRA-100" "done" "Test 1"
assert_closed_pr "INFRA-100" "999"

# ── Test 2: multi-gap closure ────────────────────────────────────────────────
echo "--- Test 2: multi-gap closure ('INFRA-200: ... + close INFRA-201') ---"
reset_repo
seed_gap "INFRA-200"
seed_gap "INFRA-201"
git -C "$FAKE_REPO" add . && git -C "$FAKE_REPO" commit -q -m "seed"
git -C "$FAKE_REPO" commit --allow-empty -q -m "INFRA-200: feature land + close INFRA-201"
( cd "$FAKE_REPO" && "$CLOSER" "HEAD~1..HEAD" 1234 ) >/dev/null 2>&1
assert_status "INFRA-200" "done" "Test 2 primary"
assert_closed_pr "INFRA-200" "1234"
assert_status "INFRA-201" "done" "Test 2 secondary"
assert_closed_pr "INFRA-201" "1234"

# ── Test 3: filing-PR safety ─────────────────────────────────────────────────
echo "--- Test 3: filing-PR safety ('chore(gaps): file INFRA-300' must NOT close) ---"
reset_repo
seed_gap "INFRA-300"
git -C "$FAKE_REPO" add . && git -C "$FAKE_REPO" commit -q -m "seed"
git -C "$FAKE_REPO" commit --allow-empty -q -m "chore(gaps): file INFRA-300 — describe new bug"
( cd "$FAKE_REPO" && "$CLOSER" "HEAD~1..HEAD" 555 ) >/dev/null 2>&1
assert_status "INFRA-300" "open" "Test 3"

# ── Test 4: opt-out tag ──────────────────────────────────────────────────────
echo "--- Test 4: [no-close] opt-out ('INFRA-400: partial — [no-close]') ---"
reset_repo
seed_gap "INFRA-400"
git -C "$FAKE_REPO" add . && git -C "$FAKE_REPO" commit -q -m "seed"
git -C "$FAKE_REPO" commit --allow-empty -q -m "INFRA-400: phase 1 only [no-close]"
( cd "$FAKE_REPO" && "$CLOSER" "HEAD~1..HEAD" 700 ) >/dev/null 2>&1
assert_status "INFRA-400" "open" "Test 4"

# ── Test 5: idempotency ──────────────────────────────────────────────────────
echo "--- Test 5: idempotency (re-run on already-done gap is no-op) ---"
reset_repo
seed_gap "INFRA-500"
git -C "$FAKE_REPO" add . && git -C "$FAKE_REPO" commit -q -m "seed"
git -C "$FAKE_REPO" commit --allow-empty -q -m "INFRA-500: ship"
( cd "$FAKE_REPO" && "$CLOSER" "HEAD~1..HEAD" 800 ) >/dev/null 2>&1
assert_closed_pr "INFRA-500" "800"
# Second run on the same range — must NOT change anything.
before=$(cat "$FAKE_REPO/docs/gaps/INFRA-500.yaml")
( cd "$FAKE_REPO" && "$CLOSER" "HEAD~1..HEAD" 999 ) >/dev/null 2>&1
after=$(cat "$FAKE_REPO/docs/gaps/INFRA-500.yaml")
if [ "$before" = "$after" ]; then
    ok "Test 5: re-run on already-done gap left file byte-identical (closed_pr stayed 800, did not flip to 999)"
else
    fail "Test 5: re-run mutated already-done gap — diff: $(diff <(echo "$before") <(echo "$after"))"
fi

# ── Test 6: missing per-file YAML — silently skipped ────────────────────────
echo "--- Test 6: missing per-file YAML — silently skipped (subject references unknown gap) ---"
reset_repo
seed_gap "INFRA-600"
git -C "$FAKE_REPO" add . && git -C "$FAKE_REPO" commit -q -m "seed"
# Commit references INFRA-600 (exists) and INFRA-999 (doesn't).
git -C "$FAKE_REPO" commit --allow-empty -q -m "INFRA-600: with mention of INFRA-999"
( cd "$FAKE_REPO" && "$CLOSER" "HEAD~1..HEAD" 333 ) >/dev/null 2>&1
assert_status "INFRA-600" "done" "Test 6 (real gap closes)"
if [ -f "$FAKE_REPO/docs/gaps/INFRA-999.yaml" ]; then
    fail "Test 6: closer must NOT create INFRA-999.yaml (the gap doesn't exist)"
else
    ok "Test 6: missing INFRA-999.yaml correctly skipped (no spurious file created)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
