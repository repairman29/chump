#!/usr/bin/env bash
# scripts/ci/test-inbox-urgent-hook.sh — INFRA-2016
#
# Validates the global urgent inbox + check-urgent reader:
#   1. CHUMP_INBOX_URGENT_DISABLE=1 → no-op
#   2. No URGENT-INBOX file → no-op, exit 0
#   3. broadcast-urgent.sh writes one CRIT message → URGENT-INBOX has entry
#   4. inbox-check-urgent.sh surfaces it as <system-reminder> with <inbox-interrupt>
#   5. Cursor advances → subsequent calls don't re-surface
#   6. EMERGENCY urgency works the same as CRIT (both surface)
#   7. --urgency INFO or missing should be rejected by broadcast-urgent.sh

set -uo pipefail
PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-2016 inbox-urgent-hook tests ==="

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
BCAST="$REPO_ROOT/scripts/coord/broadcast-urgent.sh"
READR="$REPO_ROOT/scripts/coord/inbox-check-urgent.sh"
[[ -x "$BCAST" && -x "$READR" ]] || { echo "FATAL: scripts not executable"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CHUMP_REPO CHUMP_LOCK_DIR

FAKE="$TMP/repo"
mkdir -p "$FAKE/.chump-locks"

run_bcast() {
    env CHUMP_REPO="$FAKE" \
        CHUMP_AMBIENT_LOG="$FAKE/.chump-locks/ambient.jsonl" \
        CHUMP_SESSION_ID="test-sender" \
        bash "$BCAST" "$@" 2>&1
}
run_reader() {
    env CHUMP_REPO="$FAKE" \
        CHUMP_AMBIENT_LOG="$FAKE/.chump-locks/ambient.jsonl" \
        "$@" \
        bash "$READR" 2>&1
}

# ── Test 1: disable env ─────────────────────────────────────────────────────
echo "--- Test 1: CHUMP_INBOX_URGENT_DISABLE=1 → no-op ---"
echo "fake urgent message" > "$FAKE/.chump-locks/URGENT-INBOX.jsonl"
OUT="$(run_reader CHUMP_INBOX_URGENT_DISABLE=1)"
if [[ -z "$OUT" ]]; then
    ok "disable env produced no output"
else
    fail "disable should be silent (out=$OUT)"
fi
rm -f "$FAKE/.chump-locks/URGENT-INBOX.jsonl"

# ── Test 2: no URGENT-INBOX file → silent ──────────────────────────────────
echo "--- Test 2: no URGENT-INBOX file → silent exit 0 ---"
OUT="$(run_reader)"
RC=$?
if [[ -z "$OUT" ]] && [[ $RC -eq 0 ]]; then
    ok "no file → silent + exit 0"
else
    fail "expected silent (out=$OUT, rc=$RC)"
fi

# ── Test 3: broadcast-urgent writes a CRIT message ─────────────────────────
echo "--- Test 3: broadcast-urgent --urgency CRIT writes entry ---"
OUT="$(run_bcast --urgency CRIT --to fleet-wide "trunk-RED on PR #2593 — all workers pivot")"
if [[ -f "$FAKE/.chump-locks/URGENT-INBOX.jsonl" ]] \
   && grep -q '"urgency": "CRIT"' "$FAKE/.chump-locks/URGENT-INBOX.jsonl" \
   && grep -q "trunk-RED" "$FAKE/.chump-locks/URGENT-INBOX.jsonl"; then
    ok "broadcast wrote CRIT entry to URGENT-INBOX"
else
    fail "expected URGENT-INBOX entry (file=$(cat $FAKE/.chump-locks/URGENT-INBOX.jsonl 2>/dev/null), out=$OUT)"
fi

# ── Test 4: reader surfaces it as <inbox-interrupt> ────────────────────────
echo "--- Test 4: reader surfaces as <system-reminder> wrapped <inbox-interrupt> ---"
OUT="$(run_reader)"
if echo "$OUT" | grep -q "<system-reminder>" \
   && echo "$OUT" | grep -q '<inbox-interrupt urgency="CRIT"' \
   && echo "$OUT" | grep -q "trunk-RED"; then
    ok "reader surfaced URGENT message with correct XML"
else
    fail "expected system-reminder + inbox-interrupt block (out=$(echo $OUT | head -c 300))"
fi

# ── Test 5: cursor advance → subsequent call silent ────────────────────────
echo "--- Test 5: cursor advance — second reader call is silent ---"
OUT="$(run_reader)"
if [[ -z "$OUT" ]]; then
    ok "cursor advanced; no re-surfacing"
else
    fail "expected silent on second call (out=$(echo $OUT | head -c 200))"
fi

# ── Test 6: EMERGENCY urgency surfaces ─────────────────────────────────────
echo "--- Test 6: EMERGENCY urgency also surfaces ---"
run_bcast --urgency EMERGENCY --to all "DATA LOSS imminent on PR #9999" > /dev/null
OUT="$(run_reader)"
if echo "$OUT" | grep -q '<inbox-interrupt urgency="EMERGENCY"' \
   && echo "$OUT" | grep -q "DATA LOSS"; then
    ok "EMERGENCY also surfaces correctly"
else
    fail "expected EMERGENCY surface (out=$(echo $OUT | head -c 300))"
fi

# ── Test 7: broadcast-urgent rejects INFO / missing urgency ────────────────
echo "--- Test 7: broadcast-urgent rejects INFO/missing urgency ---"
OUT="$(run_bcast "body without urgency" 2>&1)"
RC=$?
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -qi "urgency.required\|urgency must"; then
    ok "rejected missing urgency with non-zero exit"
else
    fail "expected reject + exit non-zero (rc=$RC, out=$OUT)"
fi
OUT="$(run_bcast --urgency INFO "body with INFO" 2>&1)"
RC=$?
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -qi "urgency must"; then
    ok "rejected INFO urgency"
else
    fail "expected reject INFO (rc=$RC, out=$OUT)"
fi

# ── Test 8: audit event emitted ────────────────────────────────────────────
echo "--- Test 8: audit events emitted ---"
if grep -q "urgent_broadcast_sent" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && grep -q "inbox_urgent_surfaced" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "audit events urgent_broadcast_sent + inbox_urgent_surfaced both fired"
else
    fail "expected audit events (ambient=$(cat $FAKE/.chump-locks/ambient.jsonl | tail -5))"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
