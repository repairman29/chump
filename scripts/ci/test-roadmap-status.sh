#!/usr/bin/env bash
# test-roadmap-status.sh — CI plumbing test for INFRA-606 roadmap-status.
#
# Validates:
#   1. src/roadmap_status.rs exists with required public API
#   2. `chump roadmap-status` subcommand wired in main.rs
#   3. mod roadmap_status declared in main.rs
#   4. JSON schema: render_json contains required fields (kind, weeks, ts)
#   5. parse_roadmap pub function exists
#   6. WeekOutcome / RoadmapGap / RoadmapStatusReport structs defined
#   7. 🟢/🟡/🔴 status icons present
#   8. outcome_status_icon function present
#   9. Placeholder (is_placeholder) detection present
#  10. --json flag handled in main.rs dispatch
#  11. Unit tests: >= 9 in-tree tests
set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== INFRA-606 roadmap-status plumbing test ==="
echo

# 1. Module file exists.
if [[ -f "$REPO_ROOT/src/roadmap_status.rs" ]]; then
    ok "src/roadmap_status.rs exists"
else
    fail "src/roadmap_status.rs missing"
fi

# 2. Public functions exist.
for fn in build_report parse_roadmap; do
    if grep -qE "pub fn ${fn}\b" "$REPO_ROOT/src/roadmap_status.rs" 2>/dev/null; then
        ok "pub fn $fn present"
    else
        fail "pub fn $fn missing"
    fi
done

# 3. Required structs defined.
for s in RoadmapStatusReport WeekOutcome RoadmapGap; do
    if grep -qE "pub struct ${s}\b" "$REPO_ROOT/src/roadmap_status.rs" 2>/dev/null; then
        ok "pub struct $s present"
    else
        fail "pub struct $s missing"
    fi
done

# 4. Subcommand wired in main.rs.
if grep -q 'Some("roadmap-status")' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs" 2>/dev/null; then
    ok "chump roadmap-status subcommand in main.rs"
else
    fail "roadmap-status subcommand not wired in main.rs"
fi

# 5. mod roadmap_status declared in main.rs.
if grep -q '^mod roadmap_status;' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs" 2>/dev/null; then
    ok "mod roadmap_status declared in main.rs"
else
    fail "mod roadmap_status missing from main.rs"
fi

# 6. JSON schema: render_json must contain required fields.
for field in kind roadmap_status weeks ts; do
    if grep -q "\"${field}\"" "$REPO_ROOT/src/roadmap_status.rs" 2>/dev/null; then
        ok "JSON field \"$field\" present in render_json"
    else
        fail "JSON field \"$field\" missing from render_json"
    fi
done

# 7. Status icons present (green/yellow/red).
for icon in "🟢" "🟡" "🔴"; do
    if grep -q "$icon" "$REPO_ROOT/src/roadmap_status.rs" 2>/dev/null; then
        ok "status icon $icon present"
    else
        fail "status icon $icon missing"
    fi
done

# 8. --json flag handled in main.rs dispatch.
if grep -A8 'Some("roadmap-status")' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs" 2>/dev/null | grep -q 'json'; then
    ok "--json flag handled in main.rs dispatch"
else
    fail "--json flag missing from roadmap-status dispatch in main.rs"
fi

# 9. outcome_status_icon function exists.
if grep -q 'fn outcome_status_icon' "$REPO_ROOT/src/roadmap_status.rs" 2>/dev/null; then
    ok "outcome_status_icon function present"
else
    fail "outcome_status_icon function missing"
fi

# 10. Placeholder detection (is_placeholder field).
if grep -q 'is_placeholder' "$REPO_ROOT/src/roadmap_status.rs" 2>/dev/null; then
    ok "placeholder gap detection (is_placeholder) present"
else
    fail "placeholder gap detection missing"
fi

# 11. Unit tests exist (>= 9).
test_count=$(grep -cE '#\[test\]' "$REPO_ROOT/src/roadmap_status.rs" 2>/dev/null || echo 0)
if [[ "$test_count" -ge 9 ]]; then
    ok "in-tree unit tests defined ($test_count)"
else
    fail "expected >=9 unit tests, found $test_count"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
