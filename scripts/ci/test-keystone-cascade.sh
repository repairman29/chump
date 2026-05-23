#!/usr/bin/env bash
# scripts/ci/test-keystone-cascade.sh — INFRA-1420

set -uo pipefail
PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_ROOT/src/paramedic.rs"

echo "=== INFRA-1420 keystone-cascade tests ==="

for sym in \
    "KeystoneCascade" \
    "KEYSTONE_CASCADE" \
    "extract_unblocks_cluster_trailer" \
    "recent_keystone_check_names" \
    "keystone_lookback_seconds" \
    "action_keystone_cascade" \
    "open_prs_failing_check" \
    "emit_keystone_cascade_event" \
    "keystone_cascade_fired" \
    "unblocks-cluster" \
    "CHUMP_PARAMEDIC_KEYSTONE_LOOKBACK_SECS"; do
    if grep -q "$sym" "$SRC"; then ok "paramedic.rs contains $sym"; else fail "missing $sym"; fi
done

if command -v cargo >/dev/null 2>&1 && [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
    echo ""
    if (cd "$REPO_ROOT" && cargo test --bin chump keystone_cascade_tests --quiet -- --test-threads=1 2>&1 | tail -10); then
        ok "cargo test keystone_cascade_tests passed"
    else
        fail "cargo test keystone_cascade_tests failed"
    fi
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done; exit 1; fi
echo "PASS"
