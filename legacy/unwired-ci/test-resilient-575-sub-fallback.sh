#!/usr/bin/env bash
# scripts/ci/test-resilient-575-sub-fallback.sh — RESILIENT-575
#
# Verifies the sub-outage auto-fallback added to scripts/dispatch/worker.sh:
# a worker whose sub backend (FLEET_BACKEND=claude) fails with a cap/rate/auth
# signature must switch to the free-tier cascade (chump-local) instead of
# silently cooling-down + auto-blocking the gap it happened to be running.
# Precedent: 2026-09-01, a sub-cap outage cooled-down+blocked every gap for
# 9h while the free-tier cascade sat unused the whole time.
#
#   1. classify_sub_failure() detects credit-exhausted signatures
#   2. classify_sub_failure() detects rate-limit signatures
#   3. classify_sub_failure() detects auth-invalid signatures
#   4. classify_sub_failure() returns "none" for an unrelated failure
#   5. worker.sh emits kind=fleet_backend_auto_fallback on threshold
#   6. worker.sh skips cooldown-writing for backend-outage-classified failures
#   7. worker.sh clears this worker's cooldown ledger on fallback (unblock)
#
# Exit 0 = all pass. Exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKER_SH="$REPO_ROOT/scripts/dispatch/worker.sh"

PASS=0
FAIL=0
ok()   { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*" >&2; FAIL=$((FAIL+1)); }

# Extract just the classify_sub_failure() function body and source it in
# isolation — worker.sh as a whole has launch-time side effects (heartbeat
# daemon, trap installation) that make it unsafe to source wholesale in a
# test.
_fn_tmp="$(mktemp)"
trap 'rm -f "$_fn_tmp"' EXIT
awk '/^classify_sub_failure\(\)/,/^}/' "$WORKER_SH" > "$_fn_tmp"
if [[ ! -s "$_fn_tmp" ]]; then
    fail "could not extract classify_sub_failure() from worker.sh — aborting"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
# shellcheck disable=SC1090
source "$_fn_tmp"

_logdir="$(mktemp -d)"
trap 'rm -f "$_fn_tmp"; rm -rf "$_logdir"' EXIT

# ── Test 1: credit-exhausted ─────────────────────────────────────────────────
echo 'API Error: {"type":"error","error":{"message":"Your credit balance is too low to access the Anthropic API"}}' > "$_logdir/credit.log"
_class="$(classify_sub_failure "$_logdir/credit.log")"
if [[ "$_class" == "credit-exhausted" ]]; then
    ok "Test 1: credit balance message classified as credit-exhausted"
else
    fail "Test 1: expected credit-exhausted, got '$_class'"
fi

# ── Test 2: rate-limit ───────────────────────────────────────────────────────
echo '{"type":"error","error":{"type":"rate_limit_error","message":"Number of requests too high"}}' > "$_logdir/rate.log"
_class="$(classify_sub_failure "$_logdir/rate.log")"
if [[ "$_class" == "rate-limit" ]]; then
    ok "Test 2: rate_limit_error classified as rate-limit"
else
    fail "Test 2: expected rate-limit, got '$_class'"
fi

# ── Test 3: auth-invalid ─────────────────────────────────────────────────────
echo 'Failed to authenticate. API Error: 401 Invalid authentication credentials' > "$_logdir/auth.log"
_class="$(classify_sub_failure "$_logdir/auth.log")"
if [[ "$_class" == "auth-invalid" ]]; then
    ok "Test 3: 401/auth message classified as auth-invalid"
else
    fail "Test 3: expected auth-invalid, got '$_class'"
fi

# ── Test 4: unrelated failure → none (do NOT trigger backend switch) ────────
echo 'error: could not find file src/main.rs; compilation failed' > "$_logdir/other.log"
_class="$(classify_sub_failure "$_logdir/other.log")"
if [[ "$_class" == "none" ]]; then
    ok "Test 4: unrelated compile failure classified as none"
else
    fail "Test 4: expected none, got '$_class'"
fi

# ── Test 5: fallback ambient event present in worker.sh ─────────────────────
if grep -q '"kind":"fleet_backend_auto_fallback"' "$WORKER_SH"; then
    ok "Test 5: worker.sh emits kind=fleet_backend_auto_fallback"
else
    fail "Test 5: kind=fleet_backend_auto_fallback missing from worker.sh"
fi

# ── Test 6: cooldown write is guarded by _backend_outage_fail ───────────────
if grep -q '_backend_outage_fail:-0' "$WORKER_SH"; then
    ok "Test 6: cooldown block guards on _backend_outage_fail (never blocks a gap for a backend outage)"
else
    fail "Test 6: cooldown block does not guard on _backend_outage_fail"
fi

# ── Test 7: fallback clears this worker's cooldown ledger (unblock) ─────────
if grep -q '"kind":"fleet_backend_outage_unblock"' "$WORKER_SH" \
   && grep -q 'cooldown/\${AGENT_ID}-' "$WORKER_SH"; then
    ok "Test 7: worker.sh unblocks its own cooldown ledger when the backend switches"
else
    fail "Test 7: no cooldown-unblock logic found alongside the backend fallback"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
