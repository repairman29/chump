#!/usr/bin/env bash
# scripts/ci/test-pr-explain-block.sh — INFRA-1416

set -uo pipefail
PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_ROOT/src/pr_explain.rs"

echo "=== INFRA-1416 chump pr explain-block tests ==="

[[ -f "$SRC" ]] && ok "src/pr_explain.rs exists" || { fail "missing src/pr_explain.rs"; exit 1; }

for sym in \
    "pub struct ExplainReport" \
    "pub struct CheckRow" \
    "pub fn build_report" \
    "pub fn render_text" \
    "pub fn run" \
    "FLEET_WIDE_THRESHOLD"; do
    if grep -q "$sym" "$SRC"; then ok "exports $sym"; else fail "missing $sym"; fi
done

if grep -q "^mod pr_explain;" "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "main.rs declares mod pr_explain"
else
    fail "main.rs missing pr_explain"
fi
if grep -q 'Some("explain-block")' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "main.rs dispatches pr explain-block"
else
    fail "main.rs missing explain-block dispatch"
fi

if command -v cargo >/dev/null 2>&1 && [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
    echo ""
    if (cd "$REPO_ROOT" && cargo test --bin chump pr_explain --quiet -- --test-threads=1 2>&1 | tail -10); then
        ok "cargo test pr_explain passed"
    else
        fail "cargo test pr_explain failed"
    fi
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done; exit 1; fi
echo "PASS"
