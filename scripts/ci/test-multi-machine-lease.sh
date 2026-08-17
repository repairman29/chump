#!/usr/bin/env bash
# test-multi-machine-lease.sh — INFRA-2472
#
# Validates the shared-registry lease visibility fix:
#  1. shared_registry_whois / shared_registry_whois_with_bin exist in atomic_claim.rs
#  2. check_shared_registry_gap_uniqueness gate exists and is wired into run_check_only
#  3. chump gap preflight (src/main.rs) consults the shared registry before OK
#  4. `chump-coord whois` subcommand exists (INFRA-274, the read side this gap wires up)
#  5. Functional (skips if NATS unreachable, mirrors crates/chump-coord/tests/distributed_mutex.rs):
#     simulate 2 sessions on different "machines" (distinct CHUMP_SESSION_ID, no shared
#     .chump-locks/) claiming the same gap via `chump-coord claim` — second is refused,
#     first's claim is visible to the second via `chump-coord whois`.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
ATOMIC_CLAIM_RS="$REPO_ROOT/crates/chump-atomic-claim/src/atomic_claim.rs"

echo "=== INFRA-2472 multi-machine lease visibility test ==="
echo

# 1. shared_registry_whois functions present.
if grep -q 'fn shared_registry_whois(' "$ATOMIC_CLAIM_RS" && grep -q 'fn shared_registry_whois_with_bin(' "$ATOMIC_CLAIM_RS"; then
    ok "shared_registry_whois + shared_registry_whois_with_bin exist"
else
    fail "shared_registry_whois functions missing from atomic_claim.rs"
fi

# 2. check_shared_registry_gap_uniqueness gate wired into the gate list.
if grep -q 'fn check_shared_registry_gap_uniqueness(' "$ATOMIC_CLAIM_RS"; then
    ok "check_shared_registry_gap_uniqueness function exists"
else
    fail "check_shared_registry_gap_uniqueness function missing"
fi
if grep -q 'gap-id-unique-shared' "$ATOMIC_CLAIM_RS"; then
    ok "gap-id-unique-shared gate registered in run_check_only"
else
    fail "gap-id-unique-shared gate not wired into claim gate list"
fi

# 3. chump gap preflight consults the shared registry.
if grep -q 'atomic_claim::shared_registry_whois' "$REPO_ROOT/src/main.rs"; then
    ok "chump gap preflight calls atomic_claim::shared_registry_whois"
else
    fail "chump gap preflight does not consult shared_registry_whois"
fi

# 4. chump-coord whois subcommand exists (INFRA-274 read side).
if grep -q '"whois" =>' "$REPO_ROOT/crates/chump-coord/src/main.rs"; then
    ok "chump-coord whois subcommand exists"
else
    fail "chump-coord whois subcommand missing"
fi

echo
echo "--- functional (skips if NATS unreachable) ---"

COORD_BIN="$REPO_ROOT/target/debug/chump-coord"
if [[ ! -x "$COORD_BIN" ]]; then
    COORD_BIN="$(command -v chump-coord || true)"
fi

if [[ -z "$COORD_BIN" || ! -x "$COORD_BIN" ]]; then
    echo "  SKIP: chump-coord binary not built (run: cargo build -p chump-coord)"
elif ! CHUMP_SESSION_ID="probe-$$" "$COORD_BIN" ping >/dev/null 2>&1; then
    echo "  SKIP: NATS unreachable — run: docker run -d -p 4222:4222 nats:latest -js"
else
    GAP_ID="INFRA-2472-SIM-$$-$RANDOM"
    SESSION_A="sim-machine-A-$$"
    SESSION_B="sim-machine-B-$$"

    # Session A (machine 1) claims first — must win.
    if CHUMP_SESSION_ID="$SESSION_A" "$COORD_BIN" claim "$GAP_ID" >/tmp/lease-a-$$.log 2>&1; then
        ok "session A (machine 1) claims $GAP_ID"
    else
        fail "session A claim unexpectedly rejected: $(cat /tmp/lease-a-$$.log)"
    fi

    # Session B (machine 2, no shared .chump-locks/) attempts the SAME gap — must refuse.
    if CHUMP_SESSION_ID="$SESSION_B" "$COORD_BIN" claim "$GAP_ID" >/tmp/lease-b-$$.log 2>&1; then
        fail "session B claim should have been refused (duplicate gap) but succeeded"
    else
        ok "session B (machine 2) refused — gap already held"
    fi

    # Session A's lease must be visible to session B via whois (the cross-machine signal).
    HOLDER="$(CHUMP_SESSION_ID="$SESSION_B" "$COORD_BIN" whois "$GAP_ID" 2>/dev/null || true)"
    if [[ "$HOLDER" == "$SESSION_A" ]]; then
        ok "session A's lease is visible to session B via whois ($HOLDER)"
    else
        fail "whois did not report session A as holder (got: '$HOLDER')"
    fi

    # Cleanup: release so the smoke test doesn't leak a claim in shared NATS KV.
    CHUMP_SESSION_ID="$SESSION_A" "$COORD_BIN" release "$GAP_ID" >/dev/null 2>&1 || true
    rm -f /tmp/lease-a-$$.log /tmp/lease-b-$$.log
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
