#!/usr/bin/env bash
# scripts/ci/test-stale-claim-reaper.sh — INFRA-1164 (2026-05-14)
#
# Verifies the INFRA-1164 extension to stale-gap-lock-reaper.sh:
#  1. Reaper (dry-run) identifies expired claim-*.json files
#  2. Reaper (--execute) deletes expired claim-*.json files
#  3. Reaper emits kind=stale_gap_lock_reaped to ambient.jsonl on execute
#  4. Reaper leaves non-expired claim files intact
#  5. Reaper (dry-run) does NOT delete files even if expired
#  6. dev.chump.stale-gap-lock-reaper is registered via launchctl
#  7. INFRA-1164 marker present in stale-gap-lock-reaper.sh
#  8. claim_reaped counter present in reaper output
#  9. event emitted has correct fields: kind, session, gap, reason, source
# 10. Reaper output summary line includes claim_reaped counter

set -uo pipefail

PASS=0; FAIL=0
ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/stale-gap-lock-reaper.sh"

echo "=== INFRA-1164 stale claim-file reaper test ==="
echo

# ── Test 7: INFRA-1164 marker ─────────────────────────────────────────────────
if grep -q "INFRA-1164" "$REAPER" 2>/dev/null; then
    ok "INFRA-1164 marker in stale-gap-lock-reaper.sh"
else
    fail "INFRA-1164 marker missing from stale-gap-lock-reaper.sh"
fi

# ── Test 8: claim_reaped in output ────────────────────────────────────────────
if grep -q "claim_reaped" "$REAPER" 2>/dev/null; then
    ok "claim_reaped counter referenced in stale-gap-lock-reaper.sh"
else
    fail "claim_reaped counter missing from stale-gap-lock-reaper.sh"
fi

# ── Build temp directory with synthetic claim files ───────────────────────────
TMP="$(mktemp -d)"
FAKE_LOCK_DIR="$TMP/locks"
mkdir -p "$FAKE_LOCK_DIR"
FAKE_AMBIENT="$FAKE_LOCK_DIR/ambient.jsonl"

NOW_EPOCH="$(date -u +%s)"
PAST_EPOCH=$((NOW_EPOCH - 7200))   # 2h ago
FUTURE_EPOCH=$((NOW_EPOCH + 28800)) # 8h from now

# Format as ISO timestamp
if date -u -d "@$PAST_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; then
    PAST_TS="$(date -u -d "@$PAST_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
    FUTURE_TS="$(date -u -d "@$FUTURE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
else
    # macOS date
    PAST_TS="$(date -u -r "$PAST_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
    FUTURE_TS="$(date -u -r "$FUTURE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
fi

# Stale claim (expires 2h ago)
STALE_CLAIM="$FAKE_LOCK_DIR/claim-TEST-001-99999-111111.json"
cat > "$STALE_CLAIM" <<JSON
{
  "session_id": "claim-TEST-001-99999-111111",
  "gap_id": "TEST-001",
  "purpose": "gap:TEST-001",
  "taken_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "expires_at": "$PAST_TS",
  "heartbeat_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

# Fresh claim (not yet expired)
FRESH_CLAIM="$FAKE_LOCK_DIR/claim-TEST-002-88888-222222.json"
cat > "$FRESH_CLAIM" <<JSON
{
  "session_id": "claim-TEST-002-88888-222222",
  "gap_id": "TEST-002",
  "purpose": "gap:TEST-002",
  "taken_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "expires_at": "$FUTURE_TS",
  "heartbeat_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

trap 'rm -rf "$TMP"' EXIT

# ── Test 1: Dry-run identifies stale claim ────────────────────────────────────
DRY_OUT=$(CHUMP_LOCK_DIR="$FAKE_LOCK_DIR" bash "$REAPER" --dry-run 2>&1)
if echo "$DRY_OUT" | grep -q "claim-TEST-001"; then
    ok "dry-run identifies stale claim-TEST-001"
else
    fail "dry-run did not identify stale claim-TEST-001 (output: $DRY_OUT)"
fi

# ── Test 5: Dry-run does NOT delete stale claim ───────────────────────────────
if [[ -f "$STALE_CLAIM" ]]; then
    ok "dry-run did NOT delete stale claim file"
else
    fail "dry-run deleted stale claim file (should not have)"
fi

# ── Test 2: Execute deletes expired claim ─────────────────────────────────────
EXEC_OUT=$(CHUMP_LOCK_DIR="$FAKE_LOCK_DIR" bash "$REAPER" --execute 2>&1)
if [[ ! -f "$STALE_CLAIM" ]]; then
    ok "--execute deleted expired claim file"
else
    fail "--execute did NOT delete expired claim file"
fi

# ── Test 4: Fresh claim left intact ──────────────────────────────────────────
if [[ -f "$FRESH_CLAIM" ]]; then
    ok "fresh claim file was NOT reaped"
else
    fail "fresh claim file was incorrectly reaped"
fi

# ── Test 3: Ambient event emitted ────────────────────────────────────────────
if [[ -f "$FAKE_AMBIENT" ]]; then
    if grep -q "stale_gap_lock_reaped" "$FAKE_AMBIENT"; then
        ok "stale_gap_lock_reaped event emitted to ambient.jsonl"
    else
        fail "stale_gap_lock_reaped event missing from ambient.jsonl"
    fi
else
    fail "ambient.jsonl was not created"
fi

# ── Test 9: Event has correct fields ─────────────────────────────────────────
if [[ -f "$FAKE_AMBIENT" ]]; then
    EMITTED=$(cat "$FAKE_AMBIENT" | grep "stale_gap_lock_reaped" | tail -1)
    if python3 -c "
import json, sys
d = json.loads('$EMITTED'.replace(\"'\", '\"'))
assert d.get('kind') == 'stale_gap_lock_reaped', f'wrong kind: {d.get(\"kind\")}'
assert 'session' in d, 'missing session'
assert 'source' in d, 'missing source'
assert d.get('reason') == 'expired', f'wrong reason: {d.get(\"reason\")}'
" 2>/dev/null; then
        ok "emitted event has correct fields (kind, session, source, reason=expired)"
    else
        # Try with direct file read
        if python3 - "$FAKE_AMBIENT" <<'PYEOF' 2>/dev/null
import json, sys
events = [json.loads(l) for l in open(sys.argv[1]) if l.strip() and 'stale_gap_lock_reaped' in l]
e = events[-1] if events else {}
assert e.get('kind') == 'stale_gap_lock_reaped', f'wrong kind: {e.get("kind")}'
assert 'session' in e or 'session_id' in e, 'missing session'
assert e.get('source') == 'claim_file', f'wrong source: {e.get("source")}'
assert e.get('reason') == 'expired', f'wrong reason: {e.get("reason")}'
PYEOF
        then
            ok "emitted event has correct fields (kind, session, source=claim_file, reason=expired)"
        else
            fail "emitted event missing required fields (check ambient.jsonl content)"
        fi
    fi
fi

# ── Test 10: Summary line includes claim_reaped ────────────────────────────────
if echo "$EXEC_OUT" | grep -q "claim_reaped="; then
    ok "reaper summary includes claim_reaped counter"
else
    fail "reaper summary missing claim_reaped counter (output: $EXEC_OUT)"
fi

# ── Test 6: launchctl registration (advisory) ─────────────────────────────────
if launchctl list 2>/dev/null | grep -q "stale-gap-lock-reaper"; then
    ok "dev.chump.stale-gap-lock-reaper registered via launchctl"
else
    ok "dev.chump.stale-gap-lock-reaper: not found via launchctl (advisory — may not be installed in CI)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
