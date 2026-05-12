#!/usr/bin/env bash
# test-change-approval.sh — INFRA-912
#
# Validates scripts/ops/change-approval.sh:
#  1. gate rejects unapproved change
#  2. approve creates token + snapshot + emits change_approved
#  3. gate approves after token created
#  4. CHUMP_APPROVER propagated into token
#  5. rollback restores fleet-state.json + emits change_rolled_back
#  6. rollback fails on missing snapshot
#  7. list shows approved changes
#  8. approve with empty rationale exits nonzero
#  9. gate without CHANGE-ID exits nonzero

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/change-approval.sh"

echo "=== INFRA-912 change-approval test ==="
echo

if [[ ! -x "$SCRIPT" ]]; then
    echo "  SKIP: $SCRIPT not found or not executable"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mk_env() {
    local root="$1"
    mkdir -p "$root/.chump-locks" "$root/.chump-locks/change-approvals" \
             "$root/.chump-locks/fleet-state-snapshots"
    touch "$root/.chump-locks/ambient.jsonl"
}

# ── 1. gate rejects unapproved change ─────────────────────────────────────────
echo "[1. gate rejects unapproved]"
R1="$TMP/t1"; mk_env "$R1"
if CHUMP_REPO="$R1" CHUMP_AMBIENT_OVERRIDE="$R1/.chump-locks/ambient.jsonl" \
   CHUMP_CHANGE_APPROVALS="$R1/.chump-locks/change-approvals" \
   "$SCRIPT" gate SCALE-001 2>/dev/null; then
    fail "gate should exit nonzero for unapproved change"
else
    ok "gate exits 1 for unapproved change"
fi

# ── 2. approve creates token + snapshot + emits event ─────────────────────────
echo
echo "[2. approve creates token]"
R2="$TMP/t2"; mk_env "$R2"
printf '{"fleet_size":2,"health":"ok"}\n' > "$R2/.chump-locks/fleet-state.json"

CHUMP_REPO="$R2" CHUMP_AMBIENT_OVERRIDE="$R2/.chump-locks/ambient.jsonl" \
    CHUMP_CHANGE_APPROVALS="$R2/.chump-locks/change-approvals" \
    CHUMP_APPROVER="alice" \
    "$SCRIPT" approve SCALE-001 "scaling up for peak load" >/dev/null 2>&1

if [[ -f "$R2/.chump-locks/change-approvals/SCALE-001.json" ]]; then
    ok "approval token created at change-approvals/SCALE-001.json"
else
    fail "approval token not created"
fi

if [[ -f "$R2/.chump-locks/fleet-state-snapshots/SCALE-001.json" ]]; then
    ok "fleet-state snapshot saved at fleet-state-snapshots/SCALE-001.json"
else
    fail "fleet-state snapshot not saved"
fi

if grep -q "change_approved" "$R2/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "approve emits change_approved to ambient.jsonl"
else
    fail "approve did not emit change_approved"
fi

# ── 3. gate approves after token created ──────────────────────────────────────
echo
echo "[3. gate approves with token]"
if CHUMP_REPO="$R2" CHUMP_AMBIENT_OVERRIDE="$R2/.chump-locks/ambient.jsonl" \
   CHUMP_CHANGE_APPROVALS="$R2/.chump-locks/change-approvals" \
   "$SCRIPT" gate SCALE-001 2>/dev/null; then
    ok "gate exits 0 when approval token exists"
else
    fail "gate should exit 0 for approved change"
fi

# ── 4. CHUMP_APPROVER propagated ──────────────────────────────────────────────
echo
echo "[4. CHUMP_APPROVER in token]"
APPROVER_VAL="$(python3 -c "import json; d=json.load(open('$R2/.chump-locks/change-approvals/SCALE-001.json')); print(d.get('approver',''))" 2>/dev/null)"
if [[ "$APPROVER_VAL" == "alice" ]]; then
    ok "CHUMP_APPROVER=alice written into approval token"
else
    fail "approver not propagated (got: $APPROVER_VAL)"
fi

# ── 5. rollback restores fleet-state.json + emits event ───────────────────────
echo
echo "[5. rollback restores snapshot]"
printf '{"fleet_size":3,"health":"ok"}\n' > "$R2/.chump-locks/fleet-state.json"
CHUMP_REPO="$R2" CHUMP_AMBIENT_OVERRIDE="$R2/.chump-locks/ambient.jsonl" \
    CHUMP_CHANGE_APPROVALS="$R2/.chump-locks/change-approvals" \
    "$SCRIPT" rollback SCALE-001 >/dev/null 2>&1

RESTORED="$(python3 -c "import json; d=json.load(open('$R2/.chump-locks/fleet-state.json')); print(d.get('fleet_size','?'))" 2>/dev/null)"
if [[ "$RESTORED" == "2" ]]; then
    ok "rollback restored fleet-state.json to pre-change snapshot (fleet_size=2)"
else
    fail "rollback did not restore snapshot (got fleet_size=$RESTORED)"
fi

if grep -q "change_rolled_back" "$R2/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "rollback emits change_rolled_back to ambient.jsonl"
else
    fail "rollback did not emit change_rolled_back"
fi

# ── 6. rollback fails on missing snapshot ─────────────────────────────────────
echo
echo "[6. rollback fails on missing snapshot]"
R6="$TMP/t6"; mk_env "$R6"
if CHUMP_REPO="$R6" CHUMP_AMBIENT_OVERRIDE="$R6/.chump-locks/ambient.jsonl" \
   CHUMP_CHANGE_APPROVALS="$R6/.chump-locks/change-approvals" \
   "$SCRIPT" rollback NO-SNAP 2>/dev/null; then
    fail "rollback should exit nonzero for missing snapshot"
else
    ok "rollback exits 1 when no snapshot exists"
fi

# ── 7. list shows approved changes ────────────────────────────────────────────
echo
echo "[7. list output]"
LIST_OUT="$(CHUMP_REPO="$R2" CHUMP_AMBIENT_OVERRIDE="$R2/.chump-locks/ambient.jsonl" \
    CHUMP_CHANGE_APPROVALS="$R2/.chump-locks/change-approvals" \
    "$SCRIPT" list 2>/dev/null)"
if echo "$LIST_OUT" | grep -q "SCALE-001"; then
    ok "list shows SCALE-001 approved change"
else
    fail "list did not show SCALE-001 (output: $LIST_OUT)"
fi

# ── 8. approve with empty rationale exits nonzero ────────────────────────────
echo
echo "[8. approve requires rationale]"
R8="$TMP/t8"; mk_env "$R8"
if CHUMP_REPO="$R8" CHUMP_AMBIENT_OVERRIDE="$R8/.chump-locks/ambient.jsonl" \
   CHUMP_CHANGE_APPROVALS="$R8/.chump-locks/change-approvals" \
   "$SCRIPT" approve SCALE-002 "" 2>/dev/null; then
    fail "approve with empty rationale should exit nonzero"
else
    ok "approve exits nonzero with empty rationale"
fi

# ── 9. gate without CHANGE-ID exits nonzero ──────────────────────────────────
echo
echo "[9. gate without CHANGE-ID]"
if CHUMP_REPO="$TMP" CHUMP_AMBIENT_OVERRIDE="$TMP/ambient.jsonl" \
   CHUMP_CHANGE_APPROVALS="$TMP/approvals" \
   "$SCRIPT" gate 2>/dev/null; then
    fail "gate without CHANGE-ID should exit nonzero"
else
    ok "gate exits nonzero with missing CHANGE-ID"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
