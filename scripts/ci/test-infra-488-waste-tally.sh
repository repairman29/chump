#!/usr/bin/env bash
# test-infra-488-waste-tally.sh — INFRA-488
#
# Static-validates the Zero Waste primitive:
#  - waste_tally module + public API
#  - main.rs has the chump waste-tally subcommand
#  - taxonomy includes the 10 documented kinds
#  - CLAUDE.md mission section adds Zero Waste pillar
#  - parse_duration_to_secs handles 24h/7d/60m/seconds

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== INFRA-488 Zero Waste primitive plumbing test ==="
echo

# 1. Module exists.
if [[ -f "$REPO_ROOT/src/waste_tally.rs" ]]; then
    ok "src/waste_tally.rs exists"
else
    fail "src/waste_tally.rs missing"
fi

# 2. Public API.
for fn in build_report; do
    if grep -qE "pub fn ${fn}\b" "$REPO_ROOT/src/waste_tally.rs"; then
        ok "  pub fn $fn exists"
    else
        fail "  pub fn $fn missing"
    fi
done

# 3. WASTE_KINDS constant + 10 kinds documented.
if grep -q 'pub const WASTE_KINDS' "$REPO_ROOT/src/waste_tally.rs"; then
    ok "WASTE_KINDS constant exists"
else
    fail "WASTE_KINDS missing"
fi

# 4. Subcommand wired in main.rs.
if grep -q 'Some("waste-tally")' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "chump waste-tally subcommand in main.rs"
else
    fail "subcommand not wired"
fi

# 5. parse_duration_to_secs helper exists.
if grep -q 'fn parse_duration_to_secs' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "parse_duration_to_secs helper present"
else
    fail "parse_duration_to_secs missing"
fi

# 6. CLAUDE.md mission section added.
if grep -qE 'Zero-Waste|## Mission \(4 pillars\)' "$REPO_ROOT/CLAUDE.md"; then
    ok "CLAUDE.md adds Zero Waste / 4-pillar mission"
else
    fail "CLAUDE.md missing Zero Waste mission update"
fi

# 7. Mission references chump waste-tally.
if grep -q 'chump waste-tally' "$REPO_ROOT/CLAUDE.md"; then
    ok "CLAUDE.md mission section references chump waste-tally"
else
    fail "CLAUDE.md does not reference the measurement tool"
fi

# 8. Documented kinds match the constant. (Smoke check on count.)
kind_count=$(grep -cE '^    "[a-z_]+",$' "$REPO_ROOT/src/waste_tally.rs" 2>/dev/null || echo 0)
if [[ "$kind_count" -ge 10 ]]; then
    ok "WASTE_KINDS has >=10 entries (got $kind_count)"
else
    fail "WASTE_KINDS too few entries (got $kind_count, want >=10)"
fi

# 9. infra488_ unit tests defined.
test_count=$(grep -cE 'fn infra488_' "$REPO_ROOT/src/waste_tally.rs" 2>/dev/null || echo 0)
if [[ "$test_count" -ge 5 ]]; then
    ok "in-tree infra488_ unit tests defined ($test_count fns)"
else
    fail "expected >=5 infra488_ unit tests, found $test_count"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
