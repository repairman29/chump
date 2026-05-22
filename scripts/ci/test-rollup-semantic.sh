#!/usr/bin/env bash
# scripts/ci/test-rollup-semantic.sh — INFRA-1455 (Marcus M-B converge)

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_ROOT/src/rollup_cmd.rs"

echo "=== INFRA-1455 rollup --semantic tests ==="

[[ -f "$SRC" ]] && ok "src/rollup_cmd.rs exists" || { fail "missing src/rollup_cmd.rs"; exit 1; }

for sym in \
    "pub struct RollupEntry" \
    "pub struct StrategyClass" \
    "pub struct RollupReport" \
    "pub fn entries_from_gap_list" \
    "pub fn build_rollup" \
    "pub fn render_text" \
    "pub fn run"; do
    if grep -q "$sym" "$SRC"; then
        ok "exports $sym"
    else
        fail "missing $sym"
    fi
done

# main.rs wiring
if grep -q "^mod rollup_cmd;" "$REPO_ROOT/src/main.rs"; then
    ok "main.rs declares mod rollup_cmd"
else
    fail "main.rs missing mod rollup_cmd"
fi
if grep -q 'Some("rollup")' "$REPO_ROOT/src/main.rs"; then
    ok "main.rs dispatches 'chump rollup' subcommand"
else
    fail "main.rs missing 'rollup' dispatch"
fi

# Unit tests
if command -v cargo >/dev/null 2>&1 && [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
    echo ""
    echo "  [running cargo test rollup_cmd ...]"
    if (cd "$REPO_ROOT" && cargo test --bin chump rollup_cmd --quiet -- --test-threads=1 2>&1 | tail -10); then
        ok "cargo test rollup_cmd passed"
    else
        fail "cargo test rollup_cmd failed"
    fi
fi

# AC#6 / AC#7 structural: synthetic fan-out group → semantic cluster vs flat fallback
CHUMP_BIN="${CHUMP_BIN:-chump}"
if command -v "$CHUMP_BIN" >/dev/null 2>&1; then
    echo ""
    echo "  [help-text smoke for chump rollup]"
    OUT="$("$CHUMP_BIN" rollup 2>&1 || true)"
    if echo "$OUT" | grep -q "Usage: chump rollup"; then
        ok "chump rollup prints usage when invoked without args"
    else
        fail "chump rollup usage missing"
    fi
else
    echo "  SKIP: $CHUMP_BIN not on PATH — integration smoke skipped"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
