#!/usr/bin/env bash
# scripts/ci/test-oracle-event-trigger.sh — INFRA-2123
#
# Smoke test for the event-driven Oracle refresh trigger. Verifies:
#   1. Script exists, executable, parses
#   2. Below threshold → no trigger
#   3. At/above threshold → fires + invokes oracle-refresh.sh --force
#   4. Coalescing — recent run within CHUMP_ORACLE_COALESCE_S suppresses fire
#   5. CHUMP_ORACLE_GAP_THRESHOLD is configurable
#   6. Registered in EVENT_REGISTRY.yaml

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="$REPO/scripts/ops/oracle-event-trigger.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$TARGET" ]] || fail "$TARGET missing"
[[ -x "$TARGET" ]] || fail "$TARGET not executable"
bash -n "$TARGET" || fail "syntax error"
ok "script exists, executable, parses"

grep -q 'CHUMP_ORACLE_GAP_THRESHOLD' "$TARGET" || fail "no threshold env"
ok "CHUMP_ORACLE_GAP_THRESHOLD present"

grep -q 'CHUMP_ORACLE_COALESCE_S' "$TARGET" || fail "no coalesce env"
ok "CHUMP_ORACLE_COALESCE_S present"

grep -q 'oracle_event_trigger_fired' "$TARGET" || fail "no fired event"
grep -q 'oracle_event_trigger_coalesced' "$TARGET" || fail "no coalesced event"
ok "emits oracle_event_trigger_fired + oracle_event_trigger_coalesced"

grep -q 'kind: oracle_event_trigger_fired' "$REPO/docs/observability/EVENT_REGISTRY.yaml" \
    || fail "oracle_event_trigger_fired not registered"
grep -q 'kind: oracle_event_trigger_coalesced' "$REPO/docs/observability/EVENT_REGISTRY.yaml" \
    || fail "oracle_event_trigger_coalesced not registered"
ok "both event kinds registered in EVENT_REGISTRY.yaml"

command -v jq >/dev/null 2>&1 || fail "jq required for this test but not found"

# ── Synthetic harness ──────────────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SYN="$TMP/syn-repo"
mkdir -p "$SYN/scripts/ops" "$SYN/scripts/coord" "$SYN/.chump-locks"
(cd "$SYN" && git init -q)

cp "$TARGET" "$SYN/scripts/ops/oracle-event-trigger.sh"

# Mock oracle-refresh.sh so the test never touches the real docs/network.
cat > "$SYN/scripts/coord/oracle-refresh.sh" <<'MOCK'
#!/usr/bin/env bash
echo "MOCK-ORACLE-REFRESH-INVOKED"
echo '{"ts":"2026-08-14T00:00:00Z","kind":"oracle_refresh_noop","hash":"deadbeef"}' >> "${CHUMP_AMBIENT_LOG}"
exit 0
MOCK
chmod +x "$SYN/scripts/coord/oracle-refresh.sh"

AMBIENT="$SYN/.chump-locks/ambient.jsonl"
touch "$AMBIENT"

emit_gap() {
    printf '{"ts":"%s","kind":"gap_reserved","gap_id":"INFRA-%s"}\n' "$1" "$2" >> "$AMBIENT"
}

# ── (2) Below threshold — 3 gaps, threshold 5 → no trigger ────────────────
emit_gap "2026-08-14T01:00:00Z" "100"
emit_gap "2026-08-14T01:01:00Z" "101"
emit_gap "2026-08-14T01:02:00Z" "102"

out_below=$(cd "$SYN" && CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_ORACLE_GAP_THRESHOLD=5 \
    bash scripts/ops/oracle-event-trigger.sh 2>&1)
if echo "$out_below" | grep -q "MOCK-ORACLE-REFRESH-INVOKED"; then
    fail "below-threshold run invoked oracle-refresh.sh; got: $out_below"
else
    ok "below threshold (3 < 5) → no trigger"
fi
if grep -q '"kind":"oracle_event_trigger_fired"' "$AMBIENT"; then
    fail "fired event emitted below threshold"
else
    ok "no fired event below threshold"
fi

# ── (3) At threshold — 2 more gaps (total 5) → fires ───────────────────────
emit_gap "2026-08-14T01:03:00Z" "103"
emit_gap "2026-08-14T01:04:00Z" "104"

out_fire=$(cd "$SYN" && CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_ORACLE_GAP_THRESHOLD=5 \
    bash scripts/ops/oracle-event-trigger.sh 2>&1)
if echo "$out_fire" | grep -q "MOCK-ORACLE-REFRESH-INVOKED"; then
    ok "threshold met (5 >= 5) → oracle-refresh.sh invoked"
else
    fail "threshold met but refresh not invoked; got: $out_fire"
fi
if grep -q '"kind":"oracle_event_trigger_fired"' "$AMBIENT"; then
    ok "ambient emits kind=oracle_event_trigger_fired"
else
    fail "fired event not emitted; ambient=$(cat "$AMBIENT")"
fi

# ── (4) Coalescing — refresh just ran (oracle_refresh_noop from step 3);
# 5 more gap_reserved events queued up immediately after → should coalesce
# rather than double-burst within the 1h window.
for i in 105 106 107 108 109; do
    emit_gap "2026-08-14T01:1${i: -1}:00Z" "$i"
done

out_coalesce=$(cd "$SYN" && CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_ORACLE_GAP_THRESHOLD=5 \
    CHUMP_ORACLE_COALESCE_S=999999999 \
    bash scripts/ops/oracle-event-trigger.sh 2>&1)
if echo "$out_coalesce" | grep -q "coalesce"; then
    ok "recent refresh within coalesce window → suppressed"
else
    fail "coalescing did not suppress re-fire; got: $out_coalesce"
fi
if grep -q '"kind":"oracle_event_trigger_coalesced"' "$AMBIENT"; then
    ok "ambient emits kind=oracle_event_trigger_coalesced"
else
    fail "coalesced event not emitted; ambient=$(cat "$AMBIENT")"
fi

# ── (5) Configurable threshold — CHUMP_ORACLE_GAP_THRESHOLD=2 fires early ──
SYN2="$TMP/syn-repo-2"
mkdir -p "$SYN2/scripts/ops" "$SYN2/scripts/coord" "$SYN2/.chump-locks"
cp "$TARGET" "$SYN2/scripts/ops/oracle-event-trigger.sh"
cp "$SYN/scripts/coord/oracle-refresh.sh" "$SYN2/scripts/coord/oracle-refresh.sh"
AMBIENT2="$SYN2/.chump-locks/ambient.jsonl"
touch "$AMBIENT2"
printf '{"ts":"%s","kind":"gap_reserved","gap_id":"INFRA-200"}\n' "2026-08-14T02:00:00Z" >> "$AMBIENT2"
printf '{"ts":"%s","kind":"gap_reserved","gap_id":"INFRA-201"}\n' "2026-08-14T02:01:00Z" >> "$AMBIENT2"

out_thresh=$(cd "$SYN2" && CHUMP_AMBIENT_LOG="$AMBIENT2" CHUMP_ORACLE_GAP_THRESHOLD=2 \
    bash scripts/ops/oracle-event-trigger.sh 2>&1)
if echo "$out_thresh" | grep -q "MOCK-ORACLE-REFRESH-INVOKED"; then
    ok "CHUMP_ORACLE_GAP_THRESHOLD=2 fires at 2 gaps"
else
    fail "configurable threshold not respected; got: $out_thresh"
fi

echo ""
echo "ALL INFRA-2123 oracle-event-trigger assertions passed."
