#!/usr/bin/env bash
# test-bot-merge-circuit-breaker.sh — INFRA-954
#
# Asserts:
#   1. With < threshold hangs, the breaker passes (returns 0).
#   2. With ≥ threshold hangs, the breaker trips (returns 124).
#   3. Old hangs outside the window are ignored.
#   4. `clear` writes a one-shot override; first check after passes;
#      second check applies the count again.
#   5. CHUMP_CIRCUIT_BREAKER_DISABLE=1 fully bypasses.
#   6. bot-merge.sh sources the helper.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$REPO_ROOT/scripts/coord/bot-merge-circuit-breaker.sh"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

[[ -x "$HELPER" ]]    || { echo "FAIL: $HELPER not executable"; exit 1; }
[[ -f "$BOT_MERGE" ]] || { echo "FAIL: $BOT_MERGE missing"; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOCK_DIR="$TMP/.chump-locks"
mkdir -p "$LOCK_DIR"
AMB="$LOCK_DIR/ambient.jsonl"

# Seed N synthetic bot_merge_hang events for `phase` at age_s seconds ago.
seed_hang() {
  local phase="$1" age_s="$2"
  local ts
  ts="$(python3 -c "import datetime; print((datetime.datetime.utcnow() - datetime.timedelta(seconds=$age_s)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
  printf '{"ts":"%s","event":"ALERT","kind":"bot_merge_hang","phase":"%s","timeout_secs":300,"gap_id":"INFRA-X"}\n' \
    "$ts" "$phase" >> "$AMB"
}

run_check() {
  env \
    CHUMP_AMBIENT_LOG="$AMB" \
    CHUMP_CIRCUIT_BREAKER_DIR="$LOCK_DIR" \
    REPO_ROOT="$REPO_ROOT" \
    "$@" \
    bash "$HELPER" check "cargo clippy" 2>&1
}

# 1) Empty ambient → pass.
: > "$AMB"
if ! out=$(run_check); then
  fail "scenario 1: empty ambient should pass (out: $out)"
fi
ok "scenario 1: empty ambient → pass"

# 2) 2 hangs in window → still under threshold (default 3) → pass.
: > "$AMB"
seed_hang "cargo clippy" 600
seed_hang "cargo clippy" 1200
if ! run_check >/dev/null; then
  fail "scenario 2: 2 hangs under default threshold 3 should pass"
fi
ok "scenario 2: 2 hangs (under threshold) → pass"

# 3) 3 hangs in window → trips.
seed_hang "cargo clippy" 1500
if run_check >/dev/null; then
  fail "scenario 3: 3 hangs should trip the breaker"
fi
out=$(run_check 2>&1 || true)
echo "$out" | grep -q "TRIPPED" || fail "scenario 3: tripped output missing 'TRIPPED' marker"
ok "scenario 3: 3 hangs (== threshold) → tripped"

# 4) Old hangs outside window are ignored.
: > "$AMB"
seed_hang "cargo clippy" 4000  # > default 3600 window
seed_hang "cargo clippy" 4500
seed_hang "cargo clippy" 5000
if ! run_check >/dev/null; then
  fail "scenario 4: hangs outside window should be ignored"
fi
ok "scenario 4: hangs outside window → ignored"

# 5) `clear` produces a one-shot override.
: > "$AMB"
seed_hang "cargo clippy" 600
seed_hang "cargo clippy" 800
seed_hang "cargo clippy" 1000
# Trips.
if run_check >/dev/null; then
  fail "scenario 5 setup: 3 hangs should trip"
fi
# Now clear, then check should pass once.
env CHUMP_CIRCUIT_BREAKER_DIR="$LOCK_DIR" REPO_ROOT="$REPO_ROOT" bash "$HELPER" clear >/dev/null
if ! run_check >/dev/null; then
  fail "scenario 5: post-clear check should pass once"
fi
# Second check (override consumed) should trip again.
if run_check >/dev/null; then
  fail "scenario 5: post-clear override should be one-shot — second check must trip again"
fi
ok "scenario 5: clear is one-shot (next pass, then breaker re-engages)"

# 6) CHUMP_CIRCUIT_BREAKER_DISABLE=1 fully bypasses.
: > "$AMB"
for _ in 1 2 3 4 5; do seed_hang "cargo clippy" 600; done
if ! env \
    CHUMP_AMBIENT_LOG="$AMB" \
    CHUMP_CIRCUIT_BREAKER_DIR="$LOCK_DIR" \
    CHUMP_CIRCUIT_BREAKER_DISABLE=1 \
    bash "$HELPER" check "cargo clippy" >/dev/null 2>&1; then
  fail "scenario 6: DISABLE=1 should bypass even past threshold"
fi
ok "scenario 6: CHUMP_CIRCUIT_BREAKER_DISABLE=1 → bypass"

# 7) bot-merge.sh sources the helper.
grep -q 'bot-merge-circuit-breaker.sh' "$BOT_MERGE" \
  || fail "bot-merge.sh does not source circuit-breaker helper"
ok "bot-merge.sh sources circuit-breaker helper"

echo
echo "=== test-bot-merge-circuit-breaker.sh PASSED ==="
