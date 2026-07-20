#!/usr/bin/env bash
# scripts/ci/test-gap-reserve-no-reuse.sh — INFRA-1954
#
# The INFRA-018 duplicate-ID guard only checks docs/gaps/*.yaml and
# state.db, both of which go blind to a shipped gap once its YAML mirror
# is deleted (not archived to docs/gaps/closed/) — that's how META-103,
# INFRA-1953, INFRA-1955, and INFRA-1957 were all re-issued to already-
# shipped gaps during the 2026-05-25 Cold Water cycle. `chump gap reserve`
# now cross-checks `git log --all --grep=<candidate-id>` before handing out
# an ID and rejects with DUPLICATE if the ID already appears in history.

set -uo pipefail
PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_ROOT/crates/chump-gap-store/src/lib.rs"

echo "=== INFRA-1954 gap-reserve no-ID-reuse tests ==="

for sym in \
    "fn id_referenced_in_git_history" \
    "git log --all --grep=" \
    "DUPLICATE" \
    "test_reserve_rejects_id_shipped_and_removed_from_registry"; do
    if grep -q -- "$sym" "$SRC"; then ok "gap_store contains \"$sym\""; else fail "missing \"$sym\""; fi
done

if command -v cargo >/dev/null 2>&1 && [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
    echo ""
    if (cd "$REPO_ROOT" && cargo test -p chump-gap-store reserve_rejects_id_shipped --quiet -- --test-threads=1 2>&1 | tail -20); then
        ok "cargo test reserve_rejects_id_shipped passed"
    else
        fail "cargo test reserve_rejects_id_shipped failed"
    fi
else
    fail "cargo not available — cannot run regression test"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done; exit 1; fi
echo "PASS"
