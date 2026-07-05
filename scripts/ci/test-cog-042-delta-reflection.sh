#!/usr/bin/env bash
# test-cog-042-delta-reflection.sh — COG-042
#
# Static-validates the differential-reflection plumbing:
#  1. reflect_delta.rs module exists + exports the right fns
#  2. main.rs has the chump reflect-delta subcommand
#  3. briefing.rs surfaces recent_deltas from same-domain gaps
#  4. unit tests defined (cog042_ prefix)

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== COG-042 differential-reflection plumbing test ==="
echo

# --- 1. module + public API ---
if [[ -f "$REPO_ROOT/src/reflect_delta.rs" ]]; then
    ok "src/reflect_delta.rs module exists"
else
    fail "src/reflect_delta.rs missing"
fi

for fn in emit_delta_recorded recent_deltas_for_domain; do
    if grep -qE "pub fn ${fn}\b" "$REPO_ROOT/src/reflect_delta.rs" 2>/dev/null; then
        ok "  pub fn $fn exists"
    else
        fail "  pub fn $fn missing"
    fi
done

if grep -qE 'pub struct DeltaRecord' "$REPO_ROOT/src/reflect_delta.rs"; then
    ok "  pub struct DeltaRecord exposed"
else
    fail "  DeltaRecord struct not exposed (briefing can't render)"
fi

# --- 2. main.rs has reflect-delta subcommand ---
if grep -q 'Some("reflect-delta")' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "chump reflect-delta subcommand wired"
else
    fail "reflect-delta subcommand missing"
fi

# --- 3. briefing.rs surfaces recent_deltas ---
if grep -q 'recent_deltas:' "$REPO_ROOT/src/briefing.rs" \
   && grep -q 'recent_deltas_for_domain' "$REPO_ROOT/src/briefing.rs"; then
    ok "briefing.rs populates recent_deltas via recent_deltas_for_domain"
else
    fail "briefing.rs does not populate recent_deltas"
fi

# --- 4. emit fn is panic-free (best-effort) ---
emit_block=$(awk '/pub fn emit_delta_recorded/,/^}/' "$REPO_ROOT/src/reflect_delta.rs")
if echo "$emit_block" | grep -qE '\.unwrap\(\)|\.expect\(|\bpanic!'; then
    fail "emit_delta_recorded contains unwrap/expect/panic — telemetry must be best-effort"
else
    ok "emit_delta_recorded body is panic-free"
fi

# --- 5. unit tests defined (cog042_ prefix) ---
test_count=$(grep -cE 'fn cog042_' "$REPO_ROOT/src/reflect_delta.rs" 2>/dev/null || echo 0)
if [[ "$test_count" -ge 5 ]]; then
    ok "in-tree cog042_ unit tests defined ($test_count fns; full run via cargo test --workspace)"
else
    fail "expected >=5 cog042_ unit tests, found $test_count"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
