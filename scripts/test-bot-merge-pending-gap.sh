#!/usr/bin/env bash
# test-bot-merge-pending-gap.sh — unit test for the INFRA-045 fix
# (bot-merge.sh session-ID auto-detect must also match pending_new_gap.id).
#
# Surfaced by PR #476 (2026-04-24): for new gaps reserved via gap-reserve.sh,
# the caller's lease has pending_new_gap (not gap_id), so the old auto-detect
# loop missed it and bot-merge spawned a fresh session — dropping the
# pending_new_gap reservation and causing post-rebase preflight to fail.
#
# What this test covers:
#   (1) Auto-detect picks the session when its lease has pending_new_gap.id
#       matching the target gap.
#   (2) Auto-detect picks the session when its lease has gap_id matching
#       (legacy path, must keep working).
#   (3) Auto-detect ignores leases whose pending_new_gap.id does NOT match.
#   (4) Auto-detect returns empty when no lease matches.
#
# Run:
#   ./scripts/test-bot-merge-pending-gap.sh
#
# Exits non-zero on any check failure.

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-045 bot-merge pending_new_gap auto-detect unit tests ==="
echo

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# The auto-detect snippet extracted from scripts/bot-merge.sh.
# Given a lease file and a gap ID, prints session_id if the lease owns that
# gap (either by gap_id or pending_new_gap.id), empty otherwise.
detect() {
    local lease="$1" gap="$2"
    python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    if d.get('gap_id', '') == sys.argv[2]:
        print(d.get('session_id', ''))
    else:
        p = d.get('pending_new_gap')
        if isinstance(p, dict) and p.get('id', '') == sys.argv[2]:
            print(d.get('session_id', ''))
except Exception:
    pass
" "$lease" "$gap" 2>/dev/null || true
}

# ─── Case 1: pending_new_gap.id match ────────────────────────────────────────
cat >"$TMPDIR/reserve.json" <<EOF
{
  "session_id": "chump-reserve-001",
  "paths": [],
  "taken_at": "2026-04-24T17:00:00Z",
  "expires_at": "2026-04-24T21:00:00Z",
  "heartbeat_at": "2026-04-24T17:00:00Z",
  "purpose": "gap-reserve:PRODUCT-999",
  "pending_new_gap": {"id": "PRODUCT-999", "title": "test", "domain": "PRODUCT"}
}
EOF
got="$(detect "$TMPDIR/reserve.json" "PRODUCT-999")"
if [[ "$got" == "chump-reserve-001" ]]; then
    ok "pending_new_gap.id match returns session_id"
else
    fail "pending_new_gap.id match — want 'chump-reserve-001', got '$got'"
fi

# ─── Case 2: gap_id match (legacy path) ──────────────────────────────────────
cat >"$TMPDIR/claim.json" <<EOF
{
  "session_id": "chump-claim-002",
  "paths": [],
  "taken_at": "2026-04-24T17:00:00Z",
  "expires_at": "2026-04-24T21:00:00Z",
  "heartbeat_at": "2026-04-24T17:00:00Z",
  "purpose": "gap:EXISTING-1",
  "gap_id": "EXISTING-1"
}
EOF
got="$(detect "$TMPDIR/claim.json" "EXISTING-1")"
if [[ "$got" == "chump-claim-002" ]]; then
    ok "gap_id match (legacy path) returns session_id"
else
    fail "gap_id match — want 'chump-claim-002', got '$got'"
fi

# ─── Case 3: non-matching pending_new_gap.id ─────────────────────────────────
got="$(detect "$TMPDIR/reserve.json" "PRODUCT-000")"
if [[ -z "$got" ]]; then
    ok "non-matching pending_new_gap.id returns empty"
else
    fail "non-matching pending_new_gap.id — want empty, got '$got'"
fi

# ─── Case 4: empty lease (no gap_id, no pending_new_gap) ─────────────────────
cat >"$TMPDIR/empty.json" <<EOF
{
  "session_id": "chump-empty-003",
  "paths": [],
  "taken_at": "2026-04-24T17:00:00Z",
  "expires_at": "2026-04-24T21:00:00Z",
  "heartbeat_at": "2026-04-24T17:00:00Z",
  "purpose": "other"
}
EOF
got="$(detect "$TMPDIR/empty.json" "ANY-GAP")"
if [[ -z "$got" ]]; then
    ok "lease with no gap info returns empty"
else
    fail "empty lease — want empty, got '$got'"
fi

# ─── Case 5: gap_id and pending_new_gap both set — gap_id wins (it's live) ───
cat >"$TMPDIR/both.json" <<EOF
{
  "session_id": "chump-both-004",
  "paths": [],
  "taken_at": "2026-04-24T17:00:00Z",
  "expires_at": "2026-04-24T21:00:00Z",
  "heartbeat_at": "2026-04-24T17:00:00Z",
  "purpose": "gap:LIVE-1",
  "gap_id": "LIVE-1",
  "pending_new_gap": {"id": "PENDING-1", "title": "test", "domain": "PENDING"}
}
EOF
got="$(detect "$TMPDIR/both.json" "LIVE-1")"
if [[ "$got" == "chump-both-004" ]]; then
    ok "gap_id and pending both set — gap_id match returns session"
else
    fail "gap_id priority — want 'chump-both-004' for LIVE-1, got '$got'"
fi
got="$(detect "$TMPDIR/both.json" "PENDING-1")"
if [[ "$got" == "chump-both-004" ]]; then
    ok "gap_id and pending both set — pending_new_gap match also returns session"
else
    fail "pending fallback — want 'chump-both-004' for PENDING-1, got '$got'"
fi

# ─── Case 6: malformed pending_new_gap (not a dict) — ignored ────────────────
cat >"$TMPDIR/malformed.json" <<EOF
{
  "session_id": "chump-malformed-005",
  "pending_new_gap": "not-a-dict"
}
EOF
got="$(detect "$TMPDIR/malformed.json" "anything")"
if [[ -z "$got" ]]; then
    ok "malformed pending_new_gap (non-dict) ignored"
else
    fail "malformed pending — want empty, got '$got'"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    echo
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
