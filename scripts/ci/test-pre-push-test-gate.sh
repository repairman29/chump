#!/usr/bin/env bash
# test-pre-push-test-gate.sh — INFRA-761 regression tests.
#
# Verifies the pre-push hook's Guard 0b (cargo-test full-suite gate)
# fires correctly under each scenario:
#
#   1. No .rs change in push → guard SKIPS (no cargo invocation)
#   2. .rs change + tests pass → guard PASSES + writes cache marker
#   3. .rs change + tests fail → guard BLOCKS with diagnostic
#   4. CHUMP_TEST_GATE=0 → guard SKIPS regardless
#   5. Cache marker exists for current tree → guard SKIPS (cache hit)
#
# Strategy: stub `cargo` on PATH with a controllable mock so we don't pay
# the 4-min real test runtime. The mock reads $CHUMP_TEST_GATE_FAKE_RC
# to decide pass/fail. The hook only needs `cargo` for fmt + test, both
# of which we mock. We exercise just Guard 0b — Guard 0 (fmt) is also
# mocked-pass to isolate.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-761 cargo-test gate (pre-push Guard 0b) ==="
echo

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"

if [[ ! -x "$HOOK" ]]; then
    echo "FATAL: pre-push hook not found or not executable: $HOOK"
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Mock cargo ──────────────────────────────────────────────────────────────
# The mock honours CHUMP_TEST_GATE_FAKE_RC for the test subcommand.
# fmt --check always passes (Guard 0 already covered in INFRA-749 tests).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/cargo" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
    fmt) exit 0 ;;
    test)
        # Honour CHUMP_TEST_GATE_FAKE_RC; default green.
        rc="${CHUMP_TEST_GATE_FAKE_RC:-0}"
        if [[ "$rc" != "0" ]]; then
            echo "test failed: synthetic mock failure"
            exit "$rc"
        fi
        echo "test result: ok. 1 passed; 0 failed"
        exit 0
        ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$TMP/bin/cargo"

# Set up an isolated bare "origin" + clone so the hook has refs to push.
mkdir -p "$TMP/origin.git" && (cd "$TMP/origin.git" && git init --bare -q)
git clone -q "$TMP/origin.git" "$TMP/clone"
cd "$TMP/clone"
git config user.email t@t && git config user.name t

# Seed a minimal .cargo/config.toml so the hook's awk probe (INFRA-2184) does
# not fail with exit 2 on a missing file.  The real Chump repo has this file;
# the bare clone does not.  No rustc-wrapper line → _PREPUSH_WRAPPER_BIN=""
# → wrapper probe is skipped entirely.  (INFRA-2297)
mkdir -p .cargo
printf '[build]\n' > .cargo/config.toml

# Seed a baseline commit so origin/main exists.
mkdir -p src
echo "fn baseline() {}" > src/lib.rs
git add .cargo/config.toml src/lib.rs
git commit -qm "seed"
git push -q origin HEAD:main 2>/dev/null
git branch -m main 2>/dev/null || true
git push -q --set-upstream origin main 2>/dev/null

# Helper: invoke the hook with mocked cargo on PATH.
# Stdin format isn't required — our gate falls back to origin/main diff.
run_hook() {
    PATH="$TMP/bin:$PATH" \
    CHUMP_FMT_CHECK=0 \
    CHUMP_GAP_CHECK=0 \
    CHUMP_AUTOMERGE_OVERRIDE=1 \
    CHUMP_FORCE_LEASE_CHECK=0 \
    CHUMP_REBASE_DETECT=0 \
    CHUMP_TEST_GATE_FAKE_RC="${CHUMP_TEST_GATE_FAKE_RC:-0}" \
    "$HOOK" origin "$TMP/origin.git" </dev/null 2>&1
}

# ── Test 1: no .rs change → skip ────────────────────────────────────────────
echo "--- Test 1: docs-only change → guard skips (no cargo test invocation) ---"
echo "x" > README.md
git add README.md
git commit -qm "docs only"
OUT=$(run_hook)
RC=$?
if [[ "$RC" -eq 0 ]] && ! echo "$OUT" | grep -q "INFRA-761: running cargo test"; then
    ok "docs-only push skipped the test gate"
else
    fail "docs-only push should skip (rc=$RC, out=$OUT)"
fi

# ── Test 2: .rs change + tests pass ─────────────────────────────────────────
echo "--- Test 2: .rs change + tests pass → guard passes + writes marker ---"
# Append a benign comment — compiles cleanly regardless of imports, still a
# real .rs diff that triggers the test gate's .rs-change branch (INFRA-2297).
echo "// test-pre-push-test-gate.sh synthetic change $(date +%s)" >> src/lib.rs
git add src/lib.rs
git commit -qm "rs change passing"
OUT=$(run_hook)
RC=$?
if [[ "$RC" -eq 0 ]] && echo "$OUT" | grep -q "full suite green"; then
    ok "rs-change-passing push allowed and cached"
else
    fail "rs-change-passing should pass (rc=$RC, out=$OUT)"
fi

TREE_SHA="$(git rev-parse HEAD^{tree})"
MARKER=".chump-locks/test-gate-cache/${TREE_SHA}.ok"
if [[ -f "$MARKER" ]]; then
    ok "cache marker created at $MARKER"
else
    fail "cache marker missing at $MARKER"
fi

# ── Test 3: cache hit → skip ────────────────────────────────────────────────
echo "--- Test 3: re-push of same tree → cache hit, guard skips ---"
OUT=$(run_hook)
RC=$?
if [[ "$RC" -eq 0 ]] && ! echo "$OUT" | grep -q "running cargo test"; then
    ok "cache hit silently skipped re-test"
else
    fail "cache hit should skip (rc=$RC, out=$OUT)"
fi

# ── Test 4: .rs change + tests fail → block ─────────────────────────────────
echo "--- Test 4: .rs change + tests fail → guard blocks with diagnostic ---"
# Benign comment append — same rationale as Test 2 (INFRA-2297).
echo "// test-pre-push-test-gate.sh synthetic failing-case change $(date +%s)" >> src/lib.rs
git add src/lib.rs
git commit -qm "rs change failing"
OUT=$(CHUMP_TEST_GATE_FAKE_RC=101 run_hook)
RC=$?
if [[ "$RC" -ne 0 ]] && echo "$OUT" | grep -q "BLOCKED: cargo test"; then
    ok "test failure blocks push with diagnostic"
else
    fail "test failure should block (rc=$RC, out=$OUT)"
fi

# Cache marker for the failing tree should NOT be written.
TREE_SHA_FAIL="$(git rev-parse HEAD^{tree})"
FAIL_MARKER=".chump-locks/test-gate-cache/${TREE_SHA_FAIL}.ok"
if [[ ! -f "$FAIL_MARKER" ]]; then
    ok "no cache marker written on failure"
else
    fail "cache marker should NOT exist for failed tests"
fi

# ── Test 5: bypass env → skip ───────────────────────────────────────────────
echo "--- Test 5: CHUMP_TEST_GATE=0 → guard skips even on red tests ---"
OUT=$(CHUMP_TEST_GATE=0 CHUMP_TEST_GATE_FAKE_RC=101 run_hook)
RC=$?
if [[ "$RC" -eq 0 ]] && ! echo "$OUT" | grep -q "INFRA-761: running cargo test"; then
    ok "bypass env skipped the gate"
else
    fail "bypass env should skip (rc=$RC, out=$OUT)"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
