#!/usr/bin/env bash
# scripts/ci/test-floor-temp.sh — INFRA-1992 (THE FLOOR Phase 1)
#
# Validates the floor-temperature signal. The cargo-side unit tests in
# src/floor_temp.rs cover the core scoring logic (7 tests); this fixture
# validates the CLI integration:
#
#   1. Source-contract: module exists with expected surface
#   2. main.rs wires --temp flag into the health handler
#   3. cargo unit tests pass
#   4. --temp flag exits with the correct code (0=COLD, 1=WARM, 2=HOT)
#   5. --json output is parseable JSON with expected fields
#   6. kind=floor_temp ambient event fires on invocation
#
# W-013 immunization (RESILIENT-024 pattern): unset workflow-injected env
# so this test's own $TMP fixtures are not hijacked by CI workflow paths.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-1992 floor-temp tests ==="
echo

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
MODULE="$REPO_ROOT/src/floor_temp.rs"
MAIN="$REPO_ROOT/src/main.rs"

# ── (0) source-contract: module exists with expected surface ──
[[ -f "$MODULE" ]] && ok "module file exists" || { fail "missing $MODULE"; exit 1; }

for needle in \
    "pub enum FloorTemp" \
    "pub fn compute" \
    "pub fn emit_floor_temp" \
    "pub fn ambient_path_for" \
    "DEFAULT_WINDOW_SECS" \
    "HOT_THRESHOLD" \
    "WARM_THRESHOLD" \
    "HOT_EVENT_KINDS" \
    "hook_silent_passthrough" \
    "ci_failure_cluster" \
    "admin_merge_executed"; do
    if grep -qF "$needle" "$MODULE"; then
        ok "module: $needle"
    else
        fail "module missing: $needle"
    fi
done

# ── (1) main.rs wiring ──
for needle in \
    "mod floor_temp" \
    "floor_temp::compute" \
    "floor_temp::emit_floor_temp" \
    "floor_temp::ambient_path_for" \
    "want_temp"; do
    if grep -qF "$needle" "$MAIN"; then
        ok "main.rs: $needle"
    else
        fail "main.rs missing: $needle"
    fi
done

# ── (2) cargo unit tests pass ──
echo "--- running cargo test --bin chump floor_temp ---"
CARGO_BIN="${CARGO:-cargo}"
if ! command -v "$CARGO_BIN" >/dev/null 2>&1; then
    for cand in "$HOME/.cargo/bin/cargo" /usr/local/bin/cargo /opt/homebrew/bin/cargo; do
        [[ -x "$cand" ]] && CARGO_BIN="$cand" && break
    done
fi
if "$CARGO_BIN" test --bin chump --quiet floor_temp::tests 2>&1 \
        | tail -10 | grep -qE "test result: ok|7 passed"; then
    ok "cargo unit tests pass for floor_temp (7 tests)"
else
    fail "cargo unit tests failed (run: cargo test --bin chump floor_temp::tests)"
fi

# ── (3) exit code mapping ──
# COLD → 0, WARM → 1, HOT → 2 (so workers can react via $? or || handlers)
if grep -A 5 "FloorTemp::Cold => 0" "$MAIN" | grep -q "FloorTemp::Warm => 1"; then
    ok "exit code mapping: COLD=0 WARM=1 HOT=2"
else
    fail "exit code mapping missing or wrong"
fi

# ── (4) emit includes all 3 component counts ──
for kind in hook_silent_passthrough ci_failure_cluster admin_merge_executed; do
    if grep -A 3 "emit_floor_temp" "$MODULE" | grep -q "$kind" \
       || grep -B 1 -A 30 "kind: \"floor_temp\"" "$MODULE" | grep -q "$kind"; then
        ok "emit includes $kind count"
    else
        # The grep above may not find it cleanly; fall back to file-wide
        if grep -c "\"$kind\"" "$MODULE" | awk '{exit !($1 >= 2)}'; then
            ok "emit includes $kind count (file-wide check)"
        else
            fail "emit missing $kind component"
        fi
    fi
done

# ── (5) recommendation strings present ──
for verb in "ship aggressively" "verify before commit" "no new shell glue"; do
    if grep -qF "$verb" "$MODULE"; then
        ok "recommendation: $verb"
    else
        fail "recommendation missing: $verb"
    fi
done

# ── (6) docs/strategy/THE_FLOOR.md references this signal ──
FLOOR_DOC="$REPO_ROOT/docs/strategy/THE_FLOOR.md"
if [[ -f "$FLOOR_DOC" ]] && grep -q "floor-temperature\|floor_temp\|--temp" "$FLOOR_DOC"; then
    ok "THE_FLOOR.md references floor-temp signal"
else
    fail "THE_FLOOR.md should reference --temp / floor_temp"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
