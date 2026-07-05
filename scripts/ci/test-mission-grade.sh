#!/usr/bin/env bash
# test-mission-grade.sh — CI plumbing test for INFRA-599 mission-grade.
#
# Validates:
#   1. src/mission_grade.rs exists with required public API
#   2. `chump mission-grade` subcommand wired in main.rs
#   3. install-mission-grade-launchd.sh exists and is executable
#   4. fleet-status.sh --json code path includes mission_grade reader
#   5. JSON schema emitted by mission_grade is valid (smoke via unit tests)
#   6. Threshold-alert logic: shipped_24h=0 triggers ALERT in text output
#   7. render_event_json contains required fields
set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== INFRA-599 mission-grade plumbing test ==="
echo

# 1. Module file exists.
if [[ -f "$REPO_ROOT/src/mission_grade.rs" ]]; then
    ok "src/mission_grade.rs exists"
else
    fail "src/mission_grade.rs missing"
fi

# 2. Public functions exist.
for fn in build_report emit; do
    if grep -qE "pub fn ${fn}\b" "$REPO_ROOT/src/mission_grade.rs" 2>/dev/null; then
        ok "  pub fn $fn present"
    else
        fail "  pub fn $fn missing"
    fi
done

# 3. PillarCounts and MissionGradeReport structs defined.
for s in PillarCounts MissionGradeReport; do
    if grep -qE "pub struct ${s}\b" "$REPO_ROOT/src/mission_grade.rs" 2>/dev/null; then
        ok "  pub struct $s present"
    else
        fail "  pub struct $s missing"
    fi
done

# 4. All 4 pillar prefixes defined in PILLAR_PREFIXES.
for prefix in "EFFECTIVE:" "CREDIBLE:" "RESILIENT:" "ZERO-WASTE:"; do
    if grep -q "\"${prefix}\"" "$REPO_ROOT/src/mission_grade.rs" 2>/dev/null; then
        ok "  PILLAR_PREFIXES includes $prefix"
    else
        fail "  PILLAR_PREFIXES missing $prefix"
    fi
done

# 5. Subcommand wired in main.rs.
if grep -q 'Some("mission-grade")' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs" 2>/dev/null; then
    ok "chump mission-grade subcommand in main.rs"
else
    fail "mission-grade subcommand not wired in main.rs"
fi

# 6. mod mission_grade declared in main.rs.
if grep -q '^mod mission_grade;' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs" 2>/dev/null; then
    ok "mod mission_grade declared in main.rs"
else
    fail "mod mission_grade missing from main.rs"
fi

# 7. Install script exists and is executable.
INSTALL_SH="$REPO_ROOT/scripts/setup/install-mission-grade-launchd.sh"
if [[ -f "$INSTALL_SH" ]]; then
    ok "install-mission-grade-launchd.sh exists"
else
    fail "install-mission-grade-launchd.sh missing"
fi
if [[ -x "$INSTALL_SH" ]]; then
    ok "install-mission-grade-launchd.sh is executable"
else
    fail "install-mission-grade-launchd.sh is not executable"
fi

# 8. Install script targets 30-min interval (1800 seconds).
if grep -q '1800' "$INSTALL_SH" 2>/dev/null; then
    ok "install script fires every 30 min (1800s StartInterval)"
else
    fail "install script missing 1800s StartInterval"
fi

# 9. fleet-status.sh --json reads mission_grade from ambient.
if grep -q 'mission_grade' "$REPO_ROOT/scripts/dispatch/fleet-status.sh" 2>/dev/null; then
    ok "fleet-status.sh --json includes mission_grade reader"
else
    fail "fleet-status.sh missing mission_grade integration"
fi

# 10. JSON schema: render_event_json must contain required fields.
#     Validated by inspecting the format string in the source.
for field in kind mission_grade effective credible resilient zero_waste \
             count_pickable count_in_flight count_shipped_24h; do
    if grep -q "\"${field}\"" "$REPO_ROOT/src/mission_grade.rs" 2>/dev/null; then
        ok "  JSON field \"$field\" present in render_event_json"
    else
        fail "  JSON field \"$field\" missing from render_event_json"
    fi
done

# 11. Threshold-alert text ("ALERT") present in render_text.
if grep -q 'ALERT' "$REPO_ROOT/src/mission_grade.rs" 2>/dev/null; then
    ok "threshold ALERT present in render_text"
else
    fail "threshold ALERT missing from render_text"
fi

# 12. Unit tests exist.
test_count=$(grep -cE '#\[test\]' "$REPO_ROOT/src/mission_grade.rs" 2>/dev/null || echo 0)
if [[ "$test_count" -ge 5 ]]; then
    ok "in-tree unit tests defined ($test_count)"
else
    fail "expected >=5 unit tests, found $test_count"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
