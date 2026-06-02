#!/usr/bin/env bash
# test-obs-budget-guard.sh — unit tests for INFRA-755 observability-budget
# pre-commit guard (scripts/git-hooks/pre-commit-obs-budget.sh).
#
# Acceptance criteria verified:
#   (1) under-threshold + no obs → ALLOWED (silent)
#   (2) over-threshold + no obs → WARNED (exit 0, stderr warning)
#   (3) over-threshold + tracing::info!() → ALLOWED (silent)
#   (4) over-threshold + no obs + CHUMP_OBS_BUDGET_STRICT=1 → BLOCKED (exit 1)
#   (5) over-threshold + ambient kind literal → ALLOWED (silent)
#   (6) tunable threshold via CHUMP_OBS_BUDGET_FEATURE_THRESHOLD
#
# Exits non-zero on any check failure.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-755 obs-budget guard unit tests ==="
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

# Seed a tiny baseline.
echo "fn baseline() {}" > "$FAKE_REPO/src/lib.rs"
git -C "$FAKE_REPO" add src/lib.rs
git -C "$FAKE_REPO" commit -q -m "seed"

run_hook() {
    cd "$FAKE_REPO" || exit 2
    OUT=$("$HOOK" 2>&1)
    RC=$?
    cd - >/dev/null || true
    echo "$OUT"
    return $RC
}

# Helper: write N feature lines + optional obs marker into a file.
write_feature() {
    local file=$1
    local n=$2
    local obs=$3   # "" / "tracing" / "ambient"
    : > "$file"
    for i in $(seq 1 "$n"); do
        echo "let var_$i = $i;" >> "$file"
    done
    case "$obs" in
        tracing) echo 'tracing::info!("did the thing");' >> "$file" ;;
        ambient) echo 'eprintln!("{\"kind\":\"some_event\",\"ts\":\"now\"}");' >> "$file" ;;
    esac
}

# ── Test 1: under-threshold + no obs → ALLOWED ──────────────────────────────
echo "--- Test 1: 10 feature lines, no obs → allowed ---"
write_feature "$FAKE_REPO/src/feature.rs" 10 ""
git -C "$FAKE_REPO" add src/feature.rs
if run_hook >/dev/null 2>&1; then
    ok "under-threshold no-obs allowed"
else
    fail "under-threshold no-obs should be allowed"
fi
git -C "$FAKE_REPO" reset -q HEAD src/feature.rs
rm -f "$FAKE_REPO/src/feature.rs"

# ── Test 2: over-threshold + no obs → WARNED (warn-only default) ─────────────
echo "--- Test 2: 80 feature lines, no obs → warn exit 0 (INFRA-2425) ---"
write_feature "$FAKE_REPO/src/feature.rs" 80 ""
git -C "$FAKE_REPO" add src/feature.rs
OUT=$(run_hook 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -qE "WARNING|obs-budget|INFRA-755"; then
    ok "over-threshold no-obs: warned, exit 0 (warn-only default)"
else
    fail "over-threshold no-obs should warn and exit 0 (rc=$RC, output: $OUT)"
fi
git -C "$FAKE_REPO" reset -q HEAD src/feature.rs

# ── Test 3: over-threshold + tracing → ALLOWED ──────────────────────────────
echo "--- Test 3: 80 feature lines + tracing::info!() → allowed ---"
write_feature "$FAKE_REPO/src/feature.rs" 80 "tracing"
git -C "$FAKE_REPO" add src/feature.rs
if run_hook >/dev/null 2>&1; then
    ok "over-threshold + tracing allowed"
else
    fail "over-threshold + tracing should be allowed"
fi
git -C "$FAKE_REPO" reset -q HEAD src/feature.rs

# ── Test 4: strict mode → BLOCKED (INFRA-2425 replaces old BYPASS test) ──────
echo "--- Test 4: 80 feature lines, no obs, STRICT=1 → exit 1 ---"
write_feature "$FAKE_REPO/src/feature.rs" 80 ""
git -C "$FAKE_REPO" add src/feature.rs
if CHUMP_OBS_BUDGET_STRICT=1 run_hook >/dev/null 2>&1; then
    fail "strict mode should block (exit 1)"
else
    ok "strict mode blocks offending commit"
fi
git -C "$FAKE_REPO" reset -q HEAD src/feature.rs

# ── Test 5: over-threshold + ambient kind literal → ALLOWED ─────────────────
echo "--- Test 5: 80 feature lines + ambient kind literal → allowed ---"
write_feature "$FAKE_REPO/src/feature.rs" 80 "ambient"
git -C "$FAKE_REPO" add src/feature.rs
if run_hook >/dev/null 2>&1; then
    ok "over-threshold + ambient kind allowed"
else
    fail "over-threshold + ambient kind should be allowed"
fi
git -C "$FAKE_REPO" reset -q HEAD src/feature.rs

# ── Test 6: tunable threshold + strict → blocks ─────────────────────────────
echo "--- Test 6: 30 lines no obs, threshold=20, STRICT=1 → blocked ---"
write_feature "$FAKE_REPO/src/feature.rs" 30 ""
git -C "$FAKE_REPO" add src/feature.rs
OUT=$(CHUMP_OBS_BUDGET_FEATURE_THRESHOLD=20 CHUMP_OBS_BUDGET_STRICT=1 run_hook 2>&1)
RC=$?
if [ "$RC" -ne 0 ]; then
    ok "tunable threshold + strict blocks below default"
else
    fail "tunable threshold + strict should block (rc=$RC)"
fi
git -C "$FAKE_REPO" reset -q HEAD src/feature.rs

# ── Test 6b: tunable threshold, warn-only → warns but exits 0 ───────────────
echo "--- Test 6b: 30 lines no obs, threshold=20, default mode → warn exit 0 ---"
write_feature "$FAKE_REPO/src/feature.rs" 30 ""
git -C "$FAKE_REPO" add src/feature.rs
OUT=$(CHUMP_OBS_BUDGET_FEATURE_THRESHOLD=20 run_hook 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -qiE "WARNING|obs-budget|INFRA-755"; then
    ok "tunable threshold warn-only: warns, exits 0"
else
    fail "tunable threshold warn-only should warn and exit 0 (rc=$RC, out: $OUT)"
fi
git -C "$FAKE_REPO" reset -q HEAD src/feature.rs
rm -f "$FAKE_REPO/src/feature.rs"

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
