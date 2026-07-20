#!/usr/bin/env bash
# scripts/ci/test-gap-reserve-no-reuse.sh — INFRA-1954
#
# `chump gap reserve` seeds its per-domain counter from state.db alone. If a
# gap ships and its YAML is later deleted from docs/gaps/ (rather than moved
# to docs/gaps/closed/) AND state.db loses track of it (fresh clone, DB
# reset, corrupted-and-recreated DB), the counter can go backwards and
# re-issue an ID a commit already references. This test proves the
# git-history pre-check (checked in reserve_with_external,
# crates/chump-gap-store/src/lib.rs) catches that case even when state.db
# itself has no memory of the ID.
#
# Scenario:
#   1. Reserve TEST-001 in a scratch git repo.
#   2. Commit something whose message references TEST-001 (simulates the
#      gap shipping).
#   3. Reset the domain counter to 0, so state.db "forgets" TEST-001 ever
#      existed (simulates the YAML-deleted / counter-reset failure mode).
#   4. Reserve again in the TEST domain — the fix must skip past TEST-001
#      (found in git log) and assign TEST-002, not reuse TEST-001.
#   5. Sanity: with CHUMP_RESERVE_GIT_HISTORY_CHECK=0, the guard is
#      disabled and would return TEST-001 again (proves the assertion in
#      step 4 exercises the new guard, not some other counter mechanism).
#
# Usage: bash scripts/ci/test-gap-reserve-no-reuse.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ -n "${CHUMP_BIN:-}" ]]; then
    CHUMP="$CHUMP_BIN"
elif [[ -x "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" ]]; then
    CHUMP="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
else
    CHUMP="$(command -v chump 2>/dev/null || echo chump)"
fi

PASS=0
FAIL=0
ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== INFRA-1954 gap-reserve git-history no-reuse test ==="
echo

git -C "$TMP" init -q
git -C "$TMP" config user.email "test@example.com"
git -C "$TMP" config user.name "Test"
echo "seed" > "$TMP/README.md"
git -C "$TMP" add README.md
git -C "$TMP" commit -q -m "init"

export CHUMP_REPO="$TMP"
export CHUMP_HOME="$TMP"
export CHUMP_RESERVE_SCAN_OPEN_PRS=0
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_PILLAR_BALANCE_DISABLE=1
export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
export CHUMP_DISABLE_OFFLINE_CHECK=1
export CHUMP_RESERVE_VERIFY=0

FIRST_ID=$("$CHUMP" gap reserve --domain TEST --title "no-reuse dummy gap" \
    --priority P3 --effort xs --quiet --json 2>/dev/null | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [[ "$FIRST_ID" == "TEST-001" ]]; then
    ok "initial reserve assigned TEST-001"
else
    fail "initial reserve did not assign TEST-001 (got '$FIRST_ID')"
fi

echo "ship fix for $FIRST_ID" > "$TMP/ship.txt"
git -C "$TMP" add ship.txt
git -C "$TMP" commit -q -m "fix($FIRST_ID): dummy shipped fix"

# Simulate YAML-deleted / counter-forgotten state: reset the domain counter
# and drop the gap row entirely, so state.db has zero memory of TEST-001.
sqlite3 "$TMP/.chump/state.db" \
    "UPDATE gap_counters SET next_num = 0 WHERE domain = 'TEST'; DELETE FROM gaps WHERE id = 'TEST-001';"

SECOND_ID=$("$CHUMP" gap reserve --domain TEST --title "no-reuse dummy gap 2" \
    --priority P3 --effort xs --quiet --json 2>/dev/null | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [[ "$SECOND_ID" == "TEST-002" ]]; then
    ok "reserve after counter reset skipped git-history-referenced TEST-001, assigned TEST-002"
else
    fail "reserve after counter reset did not skip TEST-001 (got '$SECOND_ID') — INFRA-1954 regression"
fi

# ── Sanity: disabling the guard reuses the ID, proving the assertion above
#    actually exercises the new check ────────────────────────────────────────
sqlite3 "$TMP/.chump/state.db" \
    "UPDATE gap_counters SET next_num = 0 WHERE domain = 'TEST'; DELETE FROM gaps WHERE id = 'TEST-001' OR id = 'TEST-002';"

THIRD_ID=$(CHUMP_RESERVE_GIT_HISTORY_CHECK=0 "$CHUMP" gap reserve --domain TEST --title "no-reuse dummy gap 3" \
    --priority P3 --effort xs --quiet --json 2>/dev/null | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [[ "$THIRD_ID" == "TEST-001" ]]; then
    ok "CHUMP_RESERVE_GIT_HISTORY_CHECK=0 reuses TEST-001 (proves guard is what blocked reuse above)"
else
    fail "expected CHUMP_RESERVE_GIT_HISTORY_CHECK=0 to reuse TEST-001 (got '$THIRD_ID')"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
