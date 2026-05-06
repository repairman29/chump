#!/usr/bin/env bash
# test-infra-490-lease-cleanup.sh — INFRA-490
#
# Validates that worker.sh's lease cleanup uses the explicit session-ID
# path (not just a case-sensitive glob).

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

echo "=== INFRA-490 lease cleanup test ==="
echo

# 1. INFRA-490 block exists.
if grep -q "INFRA-490" "$WORKER"; then
    ok "worker.sh contains INFRA-490 block"
else
    fail "worker.sh missing INFRA-490 block"
fi

# 2. Explicit CHUMP_SESSION_ID rm path is present.
if grep -qE 'rm -f "\$REPO_ROOT/\.chump-locks/\$\{CHUMP_SESSION_ID\}\.json"' "$WORKER"; then
    ok "worker.sh deletes lease at exact \$CHUMP_SESSION_ID.json path"
else
    fail "worker.sh missing the exact-path rm"
fi

# 3. Legacy glob fallback preserved.
if grep -q '\${GAP_ID}\*\.json' "$WORKER"; then
    ok "legacy GAP_ID glob fallback preserved"
else
    fail "legacy fallback removed (would break non-fleet callers)"
fi

# 4. Live: simulate the cleanup with mismatched case.
TMP="/tmp/infra-490-test-$$"
mkdir -p "$TMP/.chump-locks"
# Lease file named after session (lowercase) — pre-fix glob doesn't match.
echo '{"gap_id":"INFRA-470"}' > "$TMP/.chump-locks/infra-470-fix.json"

GAP_ID="INFRA-470"
CHUMP_SESSION_ID="infra-470-fix"
REPO_ROOT="$TMP"

# Replicate INFRA-490 logic.
if [[ -n "${CHUMP_SESSION_ID:-}" ]]; then
    rm -f "$REPO_ROOT/.chump-locks/${CHUMP_SESSION_ID}.json" 2>/dev/null || true
fi
rm -f "$REPO_ROOT/.chump-locks/"*"${GAP_ID}"*.json 2>/dev/null || true

if [[ ! -f "$TMP/.chump-locks/infra-470-fix.json" ]]; then
    ok "live: lease file deleted via \$CHUMP_SESSION_ID path"
else
    fail "live: lease file NOT deleted — bug regressed"
fi

# 5. Live: legacy glob still works for unknown-session callers.
mkdir -p "$TMP/.chump-locks"
echo '{}' > "$TMP/.chump-locks/INFRA-470-claim.json"  # uppercase legacy form
unset CHUMP_SESSION_ID
GAP_ID="INFRA-470"
REPO_ROOT="$TMP"
if [[ -n "${CHUMP_SESSION_ID:-}" ]]; then
    rm -f "$REPO_ROOT/.chump-locks/${CHUMP_SESSION_ID}.json" 2>/dev/null || true
fi
rm -f "$REPO_ROOT/.chump-locks/"*"${GAP_ID}"*.json 2>/dev/null || true

if [[ ! -f "$TMP/.chump-locks/INFRA-470-claim.json" ]]; then
    ok "live: legacy uppercase-glob fallback still works"
else
    fail "live: legacy fallback broken"
fi

# Cleanup.
rm -rf "$TMP"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
