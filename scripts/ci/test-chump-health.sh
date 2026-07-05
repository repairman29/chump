#!/usr/bin/env bash
# test-chump-health.sh — CI plumbing test for INFRA-644 chump health.
#
# Validates:
#   1. src/fleet_health.rs exists with required public API
#   2. `chump health` subcommand wired in main.rs
#   3. mod fleet_health declared in main.rs
#   4. JSON schema has all required fields
#   5. render_event_json emits kind=fleet_health
#   6. install-fleet-health-launchd.sh exists and is executable
#   7. Binary smoke test: chump health --json on clean repo produces valid JSON
#   8. Unit test count >= 6
set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== INFRA-644 chump health plumbing test ==="
echo

# 1. Module file exists.
if [[ -f "$REPO_ROOT/src/fleet_health.rs" ]]; then
    ok "src/fleet_health.rs exists"
else
    fail "src/fleet_health.rs missing"
fi

# 2. Public functions exist.
for fn in build_report emit; do
    if grep -qE "pub fn ${fn}\b" "$REPO_ROOT/src/fleet_health.rs" 2>/dev/null; then
        ok "  pub fn $fn present"
    else
        fail "  pub fn $fn missing"
    fi
done

# 3. HealthReport struct present.
if grep -qE "pub struct HealthReport\b" "$REPO_ROOT/src/fleet_health.rs" 2>/dev/null; then
    ok "pub struct HealthReport present"
else
    fail "pub struct HealthReport missing"
fi

# 4. Subcommand wired in main.rs.
if grep -q 'Some("health")' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs" 2>/dev/null; then
    ok "chump health subcommand in main.rs"
else
    fail "health subcommand not wired in main.rs"
fi

# 5. mod fleet_health declared in main.rs.
if grep -q '^mod fleet_health;' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs" 2>/dev/null; then
    ok "mod fleet_health declared in main.rs"
else
    fail "mod fleet_health missing from main.rs"
fi

# 6. JSON schema: render_event_json must contain required fields.
for field in kind fleet_health score grade worst_signal active_leases waste_incidents_2h \
             fleet_wedges_2h pr_stuck_2h over_budget ghost_gaps auth_ok commits_behind; do
    if grep -q "\"${field}\"" "$REPO_ROOT/src/fleet_health.rs" 2>/dev/null; then
        ok "  JSON field \"$field\" present"
    else
        fail "  JSON field \"$field\" missing"
    fi
done

# 7. --json and --watch flags handled.
for flag in '"--json"' '"--watch"'; do
    if grep -q "$flag" "$REPO_ROOT/src/fleet_health.rs" "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs" 2>/dev/null; then
        ok "  flag $flag handled"
    else
        fail "  flag $flag not handled"
    fi
done

# 8. install script exists and is executable.
INSTALL_SH="$REPO_ROOT/scripts/setup/install-fleet-health-launchd.sh"
if [[ -f "$INSTALL_SH" ]]; then
    ok "install-fleet-health-launchd.sh exists"
else
    fail "install-fleet-health-launchd.sh missing"
fi
if [[ -x "$INSTALL_SH" ]]; then
    ok "install-fleet-health-launchd.sh is executable"
else
    fail "install-fleet-health-launchd.sh not executable"
fi

# 9. Install script targets 3600s interval (hourly).
if grep -q '3600' "$INSTALL_SH" 2>/dev/null; then
    ok "install script fires hourly (3600s StartInterval)"
else
    fail "install script missing 3600s StartInterval"
fi

# 10. Unit tests >= 6.
test_count=$(grep -cE '#\[test\]' "$REPO_ROOT/src/fleet_health.rs" 2>/dev/null || echo 0)
if [[ "$test_count" -ge 6 ]]; then
    ok "in-tree unit tests defined ($test_count)"
else
    fail "expected >=6 unit tests, found $test_count"
fi

# 11. Binary smoke test (if built).
CHUMP="$REPO_ROOT/target/release/chump"
[[ -f "$CHUMP" ]] || CHUMP="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
if [[ -f "$CHUMP" ]]; then
    TESTDIR=$(mktemp -d)
    trap 'rm -rf "$TESTDIR"' EXIT
    cd "$TESTDIR"
    git init --quiet
    mkdir -p .chump-locks
    touch .chump-locks/ambient.jsonl

    # --json must produce output containing fleet_health kind.
    JSON=$("$CHUMP" health --json 2>/dev/null || true)
    if echo "$JSON" | grep -q '"kind":"fleet_health"'; then
        ok "binary: --json output contains kind=fleet_health"
    else
        fail "binary: --json output missing kind=fleet_health (got: ${JSON:0:200})"
    fi

    # Score must be a number 0-100.
    SCORE=$(echo "$JSON" | grep -oE '"score":[0-9]+' | grep -oE '[0-9]+' || echo "")
    if [[ -n "$SCORE" ]] && [[ "$SCORE" -ge 0 ]] && [[ "$SCORE" -le 100 ]]; then
        ok "binary: score=$SCORE is in range [0,100]"
    else
        fail "binary: score not in [0,100] (got: $SCORE)"
    fi

    # Text output must mention Fleet Health.
    TEXT=$("$CHUMP" health 2>/dev/null || true)
    if echo "$TEXT" | grep -q "Fleet Health"; then
        ok "binary: text output contains 'Fleet Health'"
    else
        fail "binary: text output missing 'Fleet Health' (got: ${TEXT:0:200})"
    fi

    # ambient.jsonl must have a fleet_health event appended.
    if grep -q '"kind":"fleet_health"' .chump-locks/ambient.jsonl 2>/dev/null; then
        ok "binary: fleet_health event emitted to ambient.jsonl"
    else
        fail "binary: fleet_health event not emitted to ambient.jsonl"
    fi
else
    echo "  SKIP: binary not built yet (run 'cargo build --release' first)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
