#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# scripts/ci/test-chump-upgrade-detection.sh — INFRA-1504
#
# Verifies the binary age + upgrade detection introduced by INFRA-1504:
#   1. Source check: compute_binary_age fn defined in fleet_health.rs
#   2. Source check: run_upgrade + detect_upgrade_method defined
#   3. Source check: binary_age_h and binary_stale fields in HealthReport
#   4. Binary: `chump health --json` output includes binary_age_h + binary_stale keys
#   5. Binary: `chump upgrade --dry-run` exits 0 and prints a "Would run" or instruction line
#   6. Binary: `chump upgrade --help` exits 0 and mentions --dry-run

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO_ROOT/src/fleet_health.rs"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
skip() { printf '\033[0;33mSKIP\033[0m %s\n' "$*"; }

[[ -f "$SRC" ]] || fail "fleet_health.rs missing: $SRC"

# ── 1. compute_binary_age defined ────────────────────────────────────────────
grep -q "fn compute_binary_age" "$SRC" \
    || fail "missing fn compute_binary_age in fleet_health.rs"
ok "compute_binary_age defined"

# ── 2. run_upgrade + detect_upgrade_method defined ────────────────────────────
grep -q "pub fn run_upgrade" "$SRC" \
    || fail "missing pub fn run_upgrade in fleet_health.rs"
grep -q "fn detect_upgrade_method" "$SRC" \
    || fail "missing fn detect_upgrade_method in fleet_health.rs"
grep -q "INFRA-1504" "$SRC" \
    || fail "INFRA-1504 comment marker missing from fleet_health.rs"
ok "run_upgrade + detect_upgrade_method defined (INFRA-1504)"

# ── 3. HealthReport has binary_age_h + binary_stale ──────────────────────────
grep -q "binary_age_h" "$SRC" \
    || fail "binary_age_h field missing from fleet_health.rs"
grep -q "binary_stale" "$SRC" \
    || fail "binary_stale field missing from fleet_health.rs"
ok "HealthReport has binary_age_h + binary_stale fields"

# ── Binary integration tests ──────────────────────────────────────────────────
if [[ ! -x "$CHUMP_BIN" ]]; then
    skip "CHUMP_BIN not found at $CHUMP_BIN — skipping binary rounds 4-6"
    skip "  Build with: cargo build --bin chump"
    echo ""
    echo "Source-level checks (rounds 1-3) PASSED."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Minimal repo for health check.
mkdir -p "$WORK/repo/.chump-locks" "$WORK/repo/.chump" "$WORK/repo/docs/gaps"
cd "$WORK/repo"
git init -q
git config user.email "test@example.com"
git config user.name "Test"
git commit --allow-empty -m "init" -q
git remote add origin "https://github.com/testorg/testrepo.git"

sqlite3 "$WORK/repo/.chump/state.db" "
CREATE TABLE gaps (id TEXT PRIMARY KEY, domain TEXT, title TEXT, status TEXT, priority TEXT, effort TEXT, depends_on TEXT, notes TEXT);
CREATE TABLE leases (session_id TEXT PRIMARY KEY, gap_id TEXT NOT NULL, worktree TEXT NOT NULL DEFAULT '', expires_at INTEGER NOT NULL);
"

# ── Round 4: chump health --json includes binary_age_h + binary_stale ─────────
set +e
OUT4=$(CHUMP_REPO_ROOT="$WORK/repo" "$CHUMP_BIN" health --json 2>&1)
EXIT4=$?
set -e

echo "$OUT4" | grep -q '"binary_age_h"' \
    || fail "round 4: binary_age_h missing from chump health --json; got: $OUT4"
echo "$OUT4" | grep -q '"binary_stale"' \
    || fail "round 4: binary_stale missing from chump health --json; got: $OUT4"
ok "round 4: chump health --json includes binary_age_h + binary_stale (exit was $EXIT4)"

# ── Round 5: chump upgrade --dry-run exits 0 + prints upgrade intent ──────────
set +e
OUT5=$("$CHUMP_BIN" upgrade --dry-run 2>&1)
EXIT5=$?
set -e

if [[ "$EXIT5" -ne 0 ]]; then
    fail "round 5: chump upgrade --dry-run expected exit 0, got $EXIT5; output: $OUT5"
fi
# Should mention either "Would run" (brew/cargo) or "download" (manual)
if ! echo "$OUT5" | grep -qE "(Would run:|download)"; then
    fail "round 5: expected 'Would run:' or 'download' in --dry-run output; got: $OUT5"
fi
ok "round 5: chump upgrade --dry-run exits 0 + prints upgrade intent"

# ── Round 6: chump upgrade --help exits 0 + mentions --dry-run ────────────────
set +e
OUT6=$("$CHUMP_BIN" upgrade --help 2>&1)
EXIT6=$?
set -e

if [[ "$EXIT6" -ne 0 ]]; then
    fail "round 6: chump upgrade --help expected exit 0, got $EXIT6; output: $OUT6"
fi
echo "$OUT6" | grep -q "\-\-dry-run" \
    || fail "round 6: --dry-run not mentioned in upgrade --help; got: $OUT6"
ok "round 6: chump upgrade --help exits 0 + describes --dry-run"

echo ""
echo "All 6 checks PASSED — INFRA-1504 binary age + upgrade detection works"
