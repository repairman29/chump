#!/usr/bin/env bash
# scripts/ci/test-inbox-urgent-hook-failures.sh — INFRA-2342
#
# Validates the failure/timeout observability added to inbox-check-urgent.sh:
#   1. python3 missing → kind=inbox_urgent_check_failed class=transient, cursor NOT advanced
#   2. malformed JSON line does not crash the reader (still exits 0, degrades gracefully)
#   3. parse/render timeout → class=transient, cursor NOT advanced (retried next tick)
#   4. cursor write failure (read-only cursor dir) → class=permanent, message still shown
#   5. success path carries duration_ms on inbox_urgent_surfaced (cost/perf proxy)

set -uo pipefail
PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-2342 inbox-urgent-hook failure-path tests ==="

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

# ── Test 1: python3 missing → class=transient, cursor not advanced ────────
echo "--- Test 1: python3 missing → transient failure, no cursor advance ---"
rm -f "$FAKE/.chump-locks/URGENT-INBOX.jsonl" "$FAKE/.chump-locks/URGENT-INBOX.cursor" "$FAKE/.chump-locks/ambient.jsonl"
run_bcast --urgency CRIT --to all "trunk-RED needs attention" > /dev/null
# Build a PATH that has every real binary except python3/python3.* — symlink
# each PATH dir's entries into one dir, skipping python3 itself, so bash/cat/
# wc/tail/head/xargs/date/mv/timeout/grep etc. all stay available.
FAKE_BIN="$TMP/no-python-bin"
mkdir -p "$FAKE_BIN"
IFS=':' read -ra _DIRS <<< "$PATH"
for d in "${_DIRS[@]}"; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do
        [[ -f "$f" && -x "$f" ]] || continue
        base="$(basename "$f")"
        [[ "$base" == python3* ]] && continue
        [[ -e "$FAKE_BIN/$base" ]] && continue
        ln -sf "$f" "$FAKE_BIN/$base" 2>/dev/null || true
    done
done
OUT="$(env CHUMP_REPO="$FAKE" CHUMP_AMBIENT_LOG="$FAKE/.chump-locks/ambient.jsonl" PATH="$FAKE_BIN" bash "$READR" 2>&1)"
CURSOR_AFTER="$(cat "$FAKE/.chump-locks/URGENT-INBOX.cursor" 2>/dev/null || echo "MISSING")"
if [[ -z "$OUT" ]] \
   && grep -q '"kind":"inbox_urgent_check_failed"' "$FAKE/.chump-locks/ambient.jsonl" \
   && grep -q '"reason":"python3_missing"' "$FAKE/.chump-locks/ambient.jsonl" \
   && grep -q '"class":"transient"' "$FAKE/.chump-locks/ambient.jsonl" \
   && [[ "$CURSOR_AFTER" == "MISSING" ]]; then
    ok "python3-missing surfaced class=transient, no output, cursor untouched"
else
    fail "expected transient failure event + no output + no cursor advance (out=$OUT cursor=$CURSOR_AFTER)"
fi

# ── Test 2: malformed JSON line does not crash, still surfaces valid lines ─
echo "--- Test 2: malformed JSON line degrades gracefully ---"
rm -f "$FAKE/.chump-locks/URGENT-INBOX.jsonl" "$FAKE/.chump-locks/URGENT-INBOX.cursor" "$FAKE/.chump-locks/ambient.jsonl"
echo '{not valid json' >> "$FAKE/.chump-locks/URGENT-INBOX.jsonl"
run_bcast --urgency CRIT --to all "still readable" > /dev/null
OUT="$(run_reader)"
RC=$?
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q "still readable"; then
    ok "malformed line skipped, valid line still surfaced, exit 0"
else
    fail "expected exit 0 + valid line surfaced despite malformed sibling (rc=$RC out=$(echo $OUT | head -c 200))"
fi

# ── Test 3: parse/render timeout → transient, cursor not advanced ─────────
echo "--- Test 3: CHUMP_INBOX_URGENT_TIMEOUT_S=0.001 forces timeout → transient ---"
rm -f "$FAKE/.chump-locks/URGENT-INBOX.jsonl" "$FAKE/.chump-locks/URGENT-INBOX.cursor" "$FAKE/.chump-locks/ambient.jsonl"
run_bcast --urgency CRIT --to all "timeout probe" > /dev/null
OUT="$(env CHUMP_REPO="$FAKE" CHUMP_AMBIENT_LOG="$FAKE/.chump-locks/ambient.jsonl" CHUMP_INBOX_URGENT_TIMEOUT_S=0.001 bash "$READR" 2>&1)"
CURSOR_AFTER="$(cat "$FAKE/.chump-locks/URGENT-INBOX.cursor" 2>/dev/null || echo "MISSING")"
if [[ -z "$OUT" ]] \
   && grep -q '"class":"transient"' "$FAKE/.chump-locks/ambient.jsonl" \
   && grep -q "timeout" "$FAKE/.chump-locks/ambient.jsonl" \
   && [[ "$CURSOR_AFTER" == "MISSING" ]]; then
    ok "0s timeout surfaced class=transient, no cursor advance"
else
    fail "expected transient timeout event + no cursor advance (out=$OUT cursor=$CURSOR_AFTER ambient=$(tail -3 "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Test 4: cursor write failure → class=permanent, message still shown ───
echo "--- Test 4: cursor dir read-only → permanent failure, message still shown ---"
rm -f "$FAKE/.chump-locks/URGENT-INBOX.jsonl" "$FAKE/.chump-locks/ambient.jsonl"
RO_CURSOR_DIR="$TMP/readonly-cursor"
mkdir -p "$RO_CURSOR_DIR"
run_bcast --urgency CRIT --to all "cursor-write-probe" > /dev/null
chmod 555 "$RO_CURSOR_DIR"
if [[ "$(id -u)" -eq 0 ]]; then
    echo "  SKIP: running as root, chmod 555 does not deny root writes — skipping permanent-class assertion"
    ok "skipped under root (permission model doesn't apply)"
else
    OUT="$(env CHUMP_REPO="$FAKE" CHUMP_AMBIENT_LOG="$FAKE/.chump-locks/ambient.jsonl" CHUMP_URGENT_INBOX_CURSOR="$RO_CURSOR_DIR/cursor" bash "$READR" 2>&1)"
    if echo "$OUT" | grep -q "cursor-write-probe" \
       && grep -q '"reason":"cursor_write_failed"' "$FAKE/.chump-locks/ambient.jsonl" \
       && grep -q '"class":"permanent"' "$FAKE/.chump-locks/ambient.jsonl"; then
        ok "cursor write failure surfaced class=permanent, message still shown"
    else
        fail "expected message shown + permanent cursor_write_failed event (out=$(echo $OUT | head -c 200) ambient=$(tail -3 "$FAKE/.chump-locks/ambient.jsonl"))"
    fi
fi
chmod 755 "$RO_CURSOR_DIR" 2>/dev/null || true

# ── Test 5: success path carries duration_ms ───────────────────────────────
echo "--- Test 5: success event carries duration_ms ---"
rm -f "$FAKE/.chump-locks/URGENT-INBOX.jsonl" "$FAKE/.chump-locks/URGENT-INBOX.cursor" "$FAKE/.chump-locks/ambient.jsonl"
run_bcast --urgency CRIT --to all "perf probe" > /dev/null
run_reader > /dev/null
if grep -q '"kind":"inbox_urgent_surfaced"' "$FAKE/.chump-locks/ambient.jsonl" \
   && grep -o '"duration_ms":[0-9]*' "$FAKE/.chump-locks/ambient.jsonl" | grep -qE '"duration_ms":[0-9]+'; then
    ok "inbox_urgent_surfaced carries numeric duration_ms"
else
    fail "expected duration_ms field on success event (ambient=$(tail -3 "$FAKE/.chump-locks/ambient.jsonl"))"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
