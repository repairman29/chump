#!/usr/bin/env bash
# test-obs-budget-warn-default.sh — INFRA-2425
#
# Smoke tests for the warn-only-by-default behaviour of the obs-budget guard.
#
# Acceptance criteria verified:
#   (1) over-threshold + no obs, default mode → warn printed to stderr, exit 0
#   (2) over-threshold + no obs, CHUMP_OBS_BUDGET_STRICT=1 → exit 1
#   (3) subject prefix "docs: foo" + 1000 lines → no warning, exit 0
#   (4) CHUMP_OBS_BUDGET_BYPASS=1 set → same warn-only outcome (var not consulted)
#
# Exits non-zero on any check failure.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-2425 obs-budget warn-default smoke tests ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit-obs-budget.sh"

if [ ! -x "$HOOK" ]; then
    echo "FATAL: hook not found or not executable: $HOOK"
    exit 2
fi

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

FAKE_REPO="$TMPDIR_BASE/repo"
mkdir -p "$FAKE_REPO/src"
git -C "$FAKE_REPO" init -q -b main
git -C "$FAKE_REPO" config user.email "test@test.com"
git -C "$FAKE_REPO" config user.name "Test"

echo "fn baseline() {}" > "$FAKE_REPO/src/lib.rs"
git -C "$FAKE_REPO" add src/lib.rs
git -C "$FAKE_REPO" commit -q -m "seed"

# Helper: write N feature lines (no obs hook) into src/feature.rs and stage it.
stage_feature() {
    local n=$1
    local file="$FAKE_REPO/src/feature.rs"
    : > "$file"
    for i in $(seq 1 "$n"); do
        echo "let var_$i = $i;" >> "$file"
    done
    git -C "$FAKE_REPO" add src/feature.rs
}

unstage() {
    git -C "$FAKE_REPO" reset -q HEAD src/feature.rs 2>/dev/null || true
    rm -f "$FAKE_REPO/src/feature.rs"
}

run_hook() {
    # $@ forwarded to hook (e.g. msg-file path)
    cd "$FAKE_REPO" || exit 2
    OUT=$("$HOOK" "$@" 2>&1)
    RC=$?
    cd - >/dev/null || true
    echo "$OUT"
    return $RC
}

# ── Test 1: warn-only by default ─────────────────────────────────────────────
echo "--- Test 1: 100 feature lines, no obs, default mode → warn exit 0 ---"
stage_feature 100
OUT=$(run_hook 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -qiE "WARNING|obs-budget|INFRA-755"; then
    ok "default mode: warn printed, exit 0"
elif [ "$RC" -eq 0 ]; then
    # Guard allowed but printed no warning — acceptable if under threshold path
    # (shouldn't happen at 100 lines with threshold 50, but be precise)
    fail "default mode: exit 0 but no warning printed (out: $OUT)"
else
    fail "default mode: should exit 0 (warn-only), got rc=$RC"
fi
unstage

# ── Test 2: strict mode blocks ────────────────────────────────────────────────
echo "--- Test 2: 100 feature lines, no obs, STRICT=1 → exit 1 ---"
stage_feature 100
OUT=$(CHUMP_OBS_BUDGET_STRICT=1 run_hook 2>&1)
RC=$?
if [ "$RC" -ne 0 ]; then
    ok "strict mode: exit 1 on violation"
else
    fail "strict mode: should exit 1, got rc=0 (out: $OUT)"
fi
unstage

# ── Test 3: docs: subject prefix → no warning, exit 0 ───────────────────────
echo "--- Test 3: docs: subject, 1000 feature lines → no warning, exit 0 ---"
stage_feature 1000
# Write a COMMIT_EDITMSG so the hook can read the subject.
MSG_FILE="$TMPDIR_BASE/COMMIT_EDITMSG"
echo "docs: update all the docs" > "$MSG_FILE"
OUT=$(run_hook "$MSG_FILE" 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -qiE "WARNING|obs-budget|INFRA-755"; then
    ok "docs: prefix: no warning, exit 0"
else
    fail "docs: prefix: expected silent exit 0, got rc=$RC out: $OUT"
fi
unstage

# ── Test 4: CHUMP_OBS_BUDGET_BYPASS=1 — still warn-only (var not consulted) ──
echo "--- Test 4: BYPASS=1 set alongside default mode → still warn-only exit 0 ---"
stage_feature 100
OUT=$(CHUMP_OBS_BUDGET_BYPASS=1 run_hook 2>&1)
RC=$?
if [ "$RC" -eq 0 ]; then
    ok "BYPASS=1 does not block (var not consulted; warn-only default still holds)"
else
    fail "BYPASS=1 should not cause exit 1 in warn-only mode (rc=$RC, out: $OUT)"
fi
# Also confirm STRICT=1 still blocks even with BYPASS=1 (BYPASS is irrelevant)
OUT2=$(CHUMP_OBS_BUDGET_BYPASS=1 CHUMP_OBS_BUDGET_STRICT=1 run_hook 2>&1)
RC2=$?
if [ "$RC2" -ne 0 ]; then
    ok "BYPASS=1 + STRICT=1 still exits 1 (BYPASS has no effect)"
else
    fail "BYPASS=1 + STRICT=1 should exit 1; BYPASS must not short-circuit strict (out: $OUT2)"
fi
unstage

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
