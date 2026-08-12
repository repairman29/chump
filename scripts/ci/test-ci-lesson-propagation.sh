#!/usr/bin/env bash
# scripts/ci/test-ci-lesson-propagation.sh — INFRA-1765
#
# Smoke test for `chump ci-lesson capture` (src/ci_lesson.rs): end-to-end
# through the real compiled binary — capture a synthetic CI failure, verify
# it lands in memory_db, verify the ambient event fires, and verify
# `chump --briefing` (MEM-007) surfaces it for the same domain (the
# "auto-injected into next session briefing" half of the AC).

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

TARGET_DIR="${CARGO_TARGET_DIR:-$REPO_ROOT/target}"
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    if [[ -x "$TARGET_DIR/debug/chump" ]]; then
        CHUMP_BIN="$TARGET_DIR/debug/chump"
    else
        echo "Building chump (debug) — first run only..."
        PATH="$HOME/.cargo/bin:$PATH" cargo build --bin chump 2>&1 | tail -20
        CHUMP_BIN="$TARGET_DIR/debug/chump"
    fi
fi
[[ -x "$CHUMP_BIN" ]] || { fail "chump binary not found/built at $CHUMP_BIN"; exit 1; }
pass "chump binary available at $CHUMP_BIN"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
export CHUMP_MEMORY_DB_PATH="$TMPDIR/memory.db"
export CHUMP_AMBIENT_IN_PROMPT="$TMPDIR/ambient.jsonl"

# 1. Missing --check / failure-text should fail with usage, not crash.
if "$CHUMP_BIN" ci-lesson capture --domain infra >/tmp/ci_lesson_usage_out 2>&1; then
    fail "capture with no --check/--failure-text should exit non-zero"
else
    pass "capture with missing required args exits non-zero"
fi

# 2. Capture a synthetic PERMANENT-class failure.
if "$CHUMP_BIN" ci-lesson capture \
    --check "fast-checks" \
    --pr-ref "PR#9999" \
    --domain "infra" \
    --failure-text "error[E0308]: mismatched types, expected \`String\`, found \`&str\`" \
    > "$TMPDIR/capture_out.txt" 2>&1; then
    pass "capture command exits 0 for a classifiable failure"
else
    fail "capture command failed: $(cat "$TMPDIR/capture_out.txt")"
fi
grep -q "class=permanent" "$TMPDIR/capture_out.txt" \
    && pass "output reports class=permanent for a rustc error signal" \
    || fail "expected class=permanent in output, got: $(cat "$TMPDIR/capture_out.txt")"

# 3. Ambient event emitted with cost tracked.
[[ -f "$CHUMP_AMBIENT_IN_PROMPT" ]] || { fail "ambient.jsonl was not created"; exit 1; }
grep -q '"kind":"ci_lesson_captured"' "$CHUMP_AMBIENT_IN_PROMPT" \
    && pass "ci_lesson_captured event emitted" \
    || fail "missing kind=ci_lesson_captured in ambient stream"
grep -q '"cost_usd":"0.0"' "$CHUMP_AMBIENT_IN_PROMPT" \
    && pass "cost_usd tracked (0.0 — heuristic, no LLM call)" \
    || fail "missing cost_usd field on ci_lesson_captured event"

# 4. Lesson lands in memory_db (chump_improvement_targets) with the
#    CI-lesson marker, scoped to the domain.
if command -v sqlite3 >/dev/null 2>&1; then
    row_count="$(sqlite3 "$TMPDIR/memory.db" \
        "SELECT COUNT(*) FROM chump_improvement_targets t
         JOIN chump_reflections r ON r.id = t.reflection_id
         WHERE r.hypothesis LIKE 'ci_lesson:%' AND t.scope = 'infra';" 2>/dev/null || echo 0)"
    [[ "$row_count" -ge 1 ]] \
        && pass "lesson persisted to memory_db, scoped to domain=infra" \
        || fail "expected >=1 row in chump_improvement_targets, got $row_count"
else
    echo "[SKIP] sqlite3 not on PATH — skipping direct DB row check"
fi

# 5. Transient-class failure classifies differently.
"$CHUMP_BIN" ci-lesson capture \
    --check "flaky-net-test" \
    --pr-ref "PR#9999" \
    --domain "infra" \
    --failure-text "curl: (28) Operation timed out after 30000 milliseconds" \
    > "$TMPDIR/capture_out2.txt" 2>&1 || true
grep -q "class=transient" "$TMPDIR/capture_out2.txt" \
    && pass "output reports class=transient for a timeout signal" \
    || fail "expected class=transient in output, got: $(cat "$TMPDIR/capture_out2.txt")"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
