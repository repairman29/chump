#!/usr/bin/env bash
# test-execute-gap-external-routing.sh — MISSION-046
#
# Guards that --execute-gap routes external_repo:OWNER/REPO gaps to
# `chump improve OWNER/REPO --apply` instead of the internal agent loop.
# Tests:
#   (a) Unit tests for the pure parser (external_repo_target_from_skills)
#   (b) Structural: routing code is wired in src/main.rs

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== MISSION-046: --execute-gap external_repo routing ==="

# ── (a) Unit tests for the parser ────────────────────────────────────────────
echo ""
echo "-- (a) Cargo unit tests for external_repo_target_from_skills --"

CARGO_OUTPUT=$(cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" \
    cargo test --bin chump mission_046_external_repo 2>&1)
CARGO_RC=$?

if [[ $CARGO_RC -eq 0 ]]; then
    ok "cargo test mission_046_external_repo exited 0"
else
    bad "cargo test mission_046_external_repo exited $CARGO_RC"
    echo "$CARGO_OUTPUT" | tail -20
fi

if echo "$CARGO_OUTPUT" | grep -q "test result: ok"; then
    ok "test result: ok present"
else
    bad "test result: ok NOT present in output"
    echo "$CARGO_OUTPUT" | tail -20
fi

for test_name in \
    "mission_046_external_repo_target_parses_single_tag" \
    "mission_046_external_repo_target_parses_in_list" \
    "mission_046_internal_gap_returns_none"; do
    if echo "$CARGO_OUTPUT" | grep -q "$test_name"; then
        ok "test $test_name ran"
    else
        bad "test $test_name NOT found in output"
    fi
done

# ── (b) Structural: routing is wired in src/main.rs ──────────────────────────
echo ""
echo "-- (b) Structural wiring in src/main.rs --"

MAIN_RS="$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"

if grep -q "external_repo_target_from_skills" "$MAIN_RS"; then
    ok "external_repo_target_from_skills present in src/main.rs"
else
    bad "external_repo_target_from_skills NOT found in src/main.rs"
fi

if grep -q "improve::run" "$MAIN_RS"; then
    ok "improve::run routing call present in src/main.rs"
else
    bad "improve::run NOT found in src/main.rs"
fi

if grep -q "MISSION-046" "$MAIN_RS"; then
    ok "MISSION-046 tag present in src/main.rs"
else
    bad "MISSION-046 tag NOT found in src/main.rs"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
