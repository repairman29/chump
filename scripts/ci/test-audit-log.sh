#!/usr/bin/env bash
# test-audit-log.sh — INFRA-1842 (CP-010: vendored BEAST-MODE AuditLogger)
#
# Smoke test for `chump audit query|retention` and the `src/audit_log.rs`
# queryable audit-log primitive. Seeds synthetic entries via the hidden
# CHUMP_TEST_MODE=1 `chump audit _test_seed` subcommand, then verifies
# filtering by action/actor/combined/time-window, plus the retention sweep.
set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

# Honor CHUMP_BIN (CI passes it explicitly); else prefer release, fall back to debug.
CHUMP="${CHUMP_BIN:-}"
if [[ -z "$CHUMP" || ! -x "$CHUMP" ]]; then
    CHUMP="$REPO_ROOT/target/release/chump"
fi
if [[ ! -x "$CHUMP" ]]; then
    CHUMP="$REPO_ROOT/target/debug/chump"
fi
if [[ ! -x "$CHUMP" ]]; then
    echo "FATAL: chump binary not built; run 'cargo build --bin chump' first"
    exit 2
fi

echo "=== INFRA-1842 chump audit query/retention smoke test ==="
echo

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
export CHUMP_STATE_DB="$TMPDIR_BASE/state.db"
export CHUMP_TEST_MODE=1

# Step 1: synthetic entries spanning two actors and two actions.
"$CHUMP" audit _test_seed --actor alice --action gap.shipped \
    --resource gap --resource-id INFRA-9001 >/dev/null
"$CHUMP" audit _test_seed --actor alice --action gap.priority_changed \
    --resource gap --resource-id INFRA-9001 >/dev/null
"$CHUMP" audit _test_seed --actor bob --action gap.shipped \
    --resource gap --resource-id INFRA-9001 >/dev/null

# Step 2: query by action — expect 2 gap.shipped rows.
COUNT_SHIPPED=$("$CHUMP" audit query --action gap.shipped --json | jq '.count')
if [[ "$COUNT_SHIPPED" == "2" ]]; then
    ok "query --action gap.shipped returns 2"
else
    fail "expected 2 gap.shipped, got $COUNT_SHIPPED"
fi

# Step 3: query by actor — expect 2 alice rows.
COUNT_ALICE=$("$CHUMP" audit query --actor alice --json | jq '.count')
if [[ "$COUNT_ALICE" == "2" ]]; then
    ok "query --actor alice returns 2"
else
    fail "expected 2 for alice, got $COUNT_ALICE"
fi

# Step 4: combined filter — expect 1 (alice + shipped).
COUNT_BOTH=$("$CHUMP" audit query --actor alice --action gap.shipped --json | jq '.count')
if [[ "$COUNT_BOTH" == "1" ]]; then
    ok "query --actor alice --action gap.shipped returns 1"
else
    fail "expected 1 alice+shipped, got $COUNT_BOTH"
fi

# Step 5: --since 1m bounds — all three were just inserted, so all qualify.
COUNT_RECENT=$("$CHUMP" audit query --since 1m --json | jq '.count')
if [[ "$COUNT_RECENT" == "3" ]]; then
    ok "query --since 1m returns 3"
else
    fail "expected 3 in 1m window, got $COUNT_RECENT"
fi

# Step 6: retention sweep — sleep past the second boundary so "now" as the
# cutoff is strictly greater than every inserted row's second-precision ts,
# then remove everything older than "now".
sleep 1.5
REMOVED=$("$CHUMP" audit retention --older-than 0s --json | jq '.removed')
if [[ "$REMOVED" -ge "3" ]]; then
    ok "retention --older-than 0s removed $REMOVED rows"
else
    fail "retention removed $REMOVED, expected >= 3"
fi

REMAINING=$("$CHUMP" audit query --json | jq '.count')
if [[ "$REMAINING" == "0" ]]; then
    ok "no rows remain after retention sweep"
else
    fail "expected 0 rows after retention, got $REMAINING"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
echo "PASS: audit log smoke test"
