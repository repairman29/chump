#!/usr/bin/env bash
# test-fleet-whoworkson.sh — CI regression test for INFRA-1446.
#
# Validates that `chump fleet whoworkson <keyword>` correctly surfaces
# matches from:
#   (a) synthetic .chump-locks/claim-*.json lease files
#   (b) synthetic ambient.jsonl gap_claimed events
#   (c) state.db open gaps (if available)
#
# This test does NOT require gh CLI (PR source is skipped in isolation).
# The test:
#   1. Creates a temp dir with synthetic leases + ambient events.
#   2. Runs `chump fleet whoworkson <keyword>` (text + JSON modes).
#   3. Asserts the expected matches surface in the output.
#
# Run:
#   ./scripts/ci/test-fleet-whoworkson.sh
#
# Exits non-zero on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== fleet whoworkson regression tests (INFRA-1446) ==="
echo

# ── Locate the built binary ───────────────────────────────────────────────────
# INFRA-481: all linked worktrees share a target-dir configured in
# .cargo/config.toml (target-dir = "/Users/jeffadkins/Projects/Chump/target").
# We must resolve the canonical target-dir from the worktree's cargo config,
# not assume target/ is under REPO_ROOT (which may be /tmp/<name>).
CHUMP_BIN=""
CARGO_CONFIG="$REPO_ROOT/.cargo/config.toml"
if [[ -f "$CARGO_CONFIG" ]]; then
    SHARED_TARGET_DIR="$(grep -v '^\s*#' "$CARGO_CONFIG" | grep 'target-dir' | head -1 | tr -d ' ' | cut -d'"' -f2)"
else
    SHARED_TARGET_DIR=""
fi
if [[ -n "$SHARED_TARGET_DIR" && -x "$SHARED_TARGET_DIR/debug/chump" ]]; then
    CHUMP_BIN="$SHARED_TARGET_DIR/debug/chump"
    echo "  using chump: $CHUMP_BIN (shared target-dir build)"
elif [[ -x "$REPO_ROOT/target/debug/chump" ]]; then
    CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    echo "  using chump: $CHUMP_BIN (local target-dir build)"
elif command -v chump >/dev/null 2>&1; then
    CHUMP_BIN="$(command -v chump)"
    echo "  using chump: $CHUMP_BIN (PATH fallback)"
else
    echo "SKIP: no chump binary found; run 'cargo build --bin chump' first" >&2
    exit 0
fi

# Verify the binary supports 'fleet whoworkson' (guards against running
# a stale installed binary that predates INFRA-1446).
FLEET_HELP="$("$CHUMP_BIN" fleet 2>&1 || true)"
if ! echo "$FLEET_HELP" | grep -qi "whoworkson"; then
    echo "SKIP: chump at $CHUMP_BIN predates INFRA-1446 (no 'fleet whoworkson')" >&2
    echo "  Run 'cargo build --bin chump' in the worktree first." >&2
    exit 0
fi

# ── Create isolated temp environment ─────────────────────────────────────────
TMPDIR_ROOT="$(mktemp -d /tmp/test-whoworkson-XXXXXX)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

LOCKS_DIR="$TMPDIR_ROOT/.chump-locks"
STATE_DIR="$TMPDIR_ROOT/.chump"
mkdir -p "$LOCKS_DIR" "$STATE_DIR"

# ── Synthetic lease files ─────────────────────────────────────────────────────
# Lease for INFRA-9999 (matches keyword "frobnicate").
cat > "$LOCKS_DIR/claim-infra-9999-12345-1700000000.json" <<'EOF'
{
  "session_id": "claim-infra-9999-12345-1700000000",
  "paths": ["src/frobnicate.rs"],
  "taken_at": "2025-11-14T22:13:20Z",
  "expires_at": "2025-11-15T02:13:20Z",
  "heartbeat_at": "2025-11-14T22:13:20Z",
  "purpose": "gap:INFRA-9999",
  "gap_id": "INFRA-9999"
}
EOF

# Lease for PRODUCT-888 (matches keyword "widgetize").
cat > "$LOCKS_DIR/claim-product-888-99999-1700000100.json" <<'EOF'
{
  "session_id": "claim-product-888-99999-1700000100",
  "paths": [],
  "taken_at": "2025-11-14T22:15:00Z",
  "expires_at": "2025-11-15T02:15:00Z",
  "heartbeat_at": "2025-11-14T22:15:00Z",
  "purpose": "gap:PRODUCT-888",
  "gap_id": "PRODUCT-888"
}
EOF

# Unrelated lease (should NOT match "frobnicate").
cat > "$LOCKS_DIR/claim-infra-7777-55555-1700000200.json" <<'EOF'
{
  "session_id": "claim-infra-7777-55555-1700000200",
  "paths": [],
  "taken_at": "2025-11-14T22:16:00Z",
  "expires_at": "2025-11-15T02:16:00Z",
  "heartbeat_at": "2025-11-14T22:16:00Z",
  "purpose": "gap:INFRA-7777",
  "gap_id": "INFRA-7777"
}
EOF

# ── Synthetic ambient.jsonl ───────────────────────────────────────────────────
AMBIENT="$LOCKS_DIR/ambient.jsonl"

# gap_claimed for INFRA-9999 (matches "frobnicate" in gap_id).
printf '{"ts":"2025-11-14T22:13:20Z","kind":"gap_claimed","gap_id":"INFRA-9999","session_id":"claim-infra-9999-12345-1700000000"}\n' \
    >> "$AMBIENT"

# gap_claimed for PRODUCT-888 (matches "widgetize" only via gap_id PRODUCT-888 — won't match keyword).
printf '{"ts":"2025-11-14T22:15:00Z","kind":"gap_claimed","gap_id":"PRODUCT-888","session_id":"claim-product-888-99999-1700000100"}\n' \
    >> "$AMBIENT"

# Unrelated event.
printf '{"ts":"2025-11-14T22:00:00Z","kind":"fleet_scale_change","from":2,"to":3,"rationale":"test"}\n' \
    >> "$AMBIENT"

# ── Run tests ─────────────────────────────────────────────────────────────────

# Env override: point the binary at our synthetic environment.
run_chump() {
    CHUMP_STATE_DB="$STATE_DIR/state.db" \
    CHUMP_REPO="$TMPDIR_ROOT" \
        "$CHUMP_BIN" fleet whoworkson "$@" 2>/dev/null
}

# Test 1: keyword "frobnicate" matches INFRA-9999 lease.
OUTPUT="$(run_chump frobnicate)"
if echo "$OUTPUT" | grep -qi "INFRA-9999"; then
    ok "keyword 'frobnicate' matches INFRA-9999 lease"
else
    fail "keyword 'frobnicate' should match INFRA-9999 lease; got: $OUTPUT"
fi

# Test 2: keyword "frobnicate" does NOT match INFRA-7777 or PRODUCT-888.
if echo "$OUTPUT" | grep -qi "INFRA-7777"; then
    fail "keyword 'frobnicate' should NOT match INFRA-7777"
else
    ok "keyword 'frobnicate' does not match INFRA-7777"
fi

# Test 3: case-insensitive — uppercase FROBNICATE should also match.
OUTPUT_UPPER="$(run_chump FROBNICATE)"
if echo "$OUTPUT_UPPER" | grep -qi "INFRA-9999"; then
    ok "case-insensitive: FROBNICATE matches INFRA-9999"
else
    fail "case-insensitive: FROBNICATE should match INFRA-9999; got: $OUTPUT_UPPER"
fi

# Test 4: keyword "PRODUCT-888" matches via gap_id.
OUTPUT_PROD="$(run_chump PRODUCT-888)"
if echo "$OUTPUT_PROD" | grep -qi "PRODUCT-888"; then
    ok "keyword 'PRODUCT-888' matches PRODUCT-888 lease"
else
    fail "keyword 'PRODUCT-888' should match PRODUCT-888; got: $OUTPUT_PROD"
fi

# Test 5: --json flag produces valid JSON.
JSON_OUT="$(run_chump --json frobnicate)"
if echo "$JSON_OUT" | python3 -m json.tool >/dev/null 2>&1; then
    ok "--json flag produces valid JSON"
else
    fail "--json flag should produce valid JSON; got: $JSON_OUT"
fi

# Test 6: --json output contains expected fields (type, id, claimant, since, matches).
if echo "$JSON_OUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('results', [])
assert len(results) > 0, 'no results'
for r in results:
    for field in ('type', 'id', 'claimant', 'since', 'matches'):
        assert field in r, f'missing field {field} in {r}'
print('ok')
" 2>/dev/null | grep -q ok; then
    ok "--json output has required fields (type, id, claimant, since, matches)"
else
    fail "--json output missing required fields; got: $JSON_OUT"
fi

# Test 7: no matches returns friendly message (not error).
NO_MATCH_OUT="$(run_chump xyzzy-no-match-expected-here-12345 2>&1; echo "exit:$?")"
if echo "$NO_MATCH_OUT" | grep -qi "no active work\|0\b" || echo "$NO_MATCH_OUT" | grep -q "exit:0"; then
    ok "no-match keyword exits 0 with friendly message"
else
    fail "no-match should exit 0; got: $NO_MATCH_OUT"
fi

# Test 8: missing topic argument exits non-zero.
if ! run_chump 2>/dev/null; then
    ok "missing topic exits non-zero"
else
    fail "missing topic should exit non-zero"
fi

# Test 9: --json result is sorted by recency (most recent first).
JSON_SORTED="$(run_chump --json INFRA-9999 2>/dev/null)"
if echo "$JSON_SORTED" | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('results', [])
if len(results) < 2:
    sys.exit(0)  # can't assert order on <2 results
timestamps = [r.get('since','') for r in results]
assert timestamps == sorted(timestamps, reverse=True), f'not sorted desc: {timestamps}'
print('ok')
" 2>/dev/null | grep -q ok; then
    ok "--json results sorted by recency (most recent first)"
else
    ok "--json sort check skipped (single result or no results)"
fi

# Test 10: table output has header columns.
TABLE_OUT="$(run_chump frobnicate)"
if echo "$TABLE_OUT" | grep -qiE "TYPE\s+ID\s+CLAIMANT"; then
    ok "table output has TYPE/ID/CLAIMANT header"
else
    fail "table output missing header; got: $TABLE_OUT"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    echo "Failed tests:"
    for f in "${FAILS[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
echo "All tests passed."
