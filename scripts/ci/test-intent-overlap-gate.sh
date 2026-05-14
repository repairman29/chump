#!/usr/bin/env bash
# scripts/ci/test-intent-overlap-gate.sh — INFRA-1116
#
# Verifies intent-overlap-check.sh end-to-end:
#   1. No INTENTs in ambient → exit 0 (clear)
#   2. Other-session INTENT on disjoint paths → exit 0
#   3. Other-session INTENT on overlapping paths + live lease → exit 14
#   4. Other-session INTENT on overlapping paths but expired lease → exit 0 (stale filter)
#   5. Own-session INTENT on overlapping paths → exit 0 (self-skip)
#   6. INTENT outside time window → exit 0 (window filter)
#   7. CHUMP_CLAIM_FORCE_OVERLAP=1 with reason → exit 0 + audit event
#   8. EVENT_REGISTRY.yaml registers intent_overlap_detected + intent_overlap_overridden

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

cd "$TMP"
git init --quiet
mkdir -p scripts/coord .chump-locks
cp "$REPO_ROOT/scripts/coord/intent-overlap-check.sh" scripts/coord/
chmod +x scripts/coord/*.sh

LOCK="$TMP/.chump-locks"
AMBIENT="$LOCK/ambient.jsonl"
CHECK="scripts/coord/intent-overlap-check.sh"

# Helper: write an INTENT event into ambient
write_intent() {
    local session="$1" gap="$2" files="$3" ts="${4:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    printf '{"event": "INTENT", "session": "%s", "ts": "%s", "gap": "%s", "files": "%s"}\n' \
        "$session" "$ts" "$gap" "$files" >> "$AMBIENT"
}
# Helper: write a lease file
write_lease() {
    local session="$1" expires="$2"
    cat > "$LOCK/$session.json" <<EOF
{"session_id":"$session","expires_at":"$expires"}
EOF
}

# ── Test 1: empty ambient → clear ───────────────────────────────────────────
rm -f "$AMBIENT"
CHUMP_SESSION_ID=me bash $CHECK GAP-1 "src/main.rs" >/dev/null 2>&1
rc=$?
if [[ "$rc" -eq 0 ]]; then ok "no INTENTs: exit 0"; else fail "test 1 rc=$rc"; fi

# ── Test 2: other-session INTENT on disjoint paths → clear ──────────────────
rm -f "$AMBIENT"
write_lease sibling "2099-01-01T00:00:00Z"
write_intent sibling GAP-9 "docs/process/X.md"
CHUMP_SESSION_ID=me bash $CHECK GAP-1 "src/main.rs" >/dev/null 2>&1
rc=$?
if [[ "$rc" -eq 0 ]]; then ok "disjoint paths: exit 0"; else fail "test 2 rc=$rc"; fi

# ── Test 3: other-session INTENT on overlapping paths + live → refuse ───────
rm -f "$AMBIENT"
write_lease sibling "2099-01-01T00:00:00Z"
write_intent sibling GAP-9 "src/main.rs,scripts/coord/"
CHUMP_SESSION_ID=me bash $CHECK GAP-1 "src/main.rs" 2>/dev/null
rc=$?
if [[ "$rc" -eq 14 ]]; then ok "overlapping paths + live lease: exit 14"; else fail "test 3 rc=$rc"; fi

# Test 3b: intent_overlap_detected event was emitted
if grep -qE '"kind": ?"intent_overlap_detected"' "$AMBIENT"; then
    ok "intent_overlap_detected event emitted on refusal"
else
    fail "test 3b: no intent_overlap_detected event"
fi

# ── Test 4: other-session INTENT but lease expired → clear (stale filter) ──
rm -f "$AMBIENT"
write_lease sibling "2020-01-01T00:00:00Z"   # past
write_intent sibling GAP-9 "src/main.rs"
CHUMP_SESSION_ID=me bash $CHECK GAP-1 "src/main.rs" >/dev/null 2>&1
rc=$?
if [[ "$rc" -eq 0 ]]; then ok "expired lease: stale-filtered, exit 0"; else fail "test 4 rc=$rc"; fi

# ── Test 5: own-session INTENT → self-skip → clear ──────────────────────────
rm -f "$AMBIENT"
write_lease me "2099-01-01T00:00:00Z"
write_intent me GAP-1 "src/main.rs"
CHUMP_SESSION_ID=me bash $CHECK GAP-1 "src/main.rs" >/dev/null 2>&1
rc=$?
if [[ "$rc" -eq 0 ]]; then ok "own-session INTENT: self-skip, exit 0"; else fail "test 5 rc=$rc"; fi

# ── Test 6: INTENT outside window → clear ───────────────────────────────────
rm -f "$AMBIENT"
write_lease sibling "2099-01-01T00:00:00Z"
write_intent sibling GAP-9 "src/main.rs" "2020-01-01T00:00:00Z"   # ancient
CHUMP_SESSION_ID=me bash $CHECK GAP-1 "src/main.rs" >/dev/null 2>&1
rc=$?
if [[ "$rc" -eq 0 ]]; then ok "INTENT outside window: exit 0"; else fail "test 6 rc=$rc"; fi

# ── Test 7: force-override with reason → exit 0 + audit event ──────────────
rm -f "$AMBIENT"
write_lease sibling "2099-01-01T00:00:00Z"
write_intent sibling GAP-9 "src/main.rs"
CHUMP_SESSION_ID=me CHUMP_CLAIM_FORCE_OVERLAP=1 CHUMP_CLAIM_OVERRIDE_REASON="cherry-pick" \
    bash $CHECK GAP-1 "src/main.rs" >/dev/null 2>&1
rc=$?
if [[ "$rc" -eq 0 ]] && grep -qE '"kind": ?"intent_overlap_overridden"' "$AMBIENT" \
   && grep -qE '"reason": ?"cherry-pick"' "$AMBIENT"; then
    ok "force-override: exit 0 + intent_overlap_overridden event with reason"
else
    fail "test 7 rc=$rc ambient=$(cat "$AMBIENT" 2>/dev/null | head -2)"
fi

# ── Test 8: EVENT_REGISTRY.yaml registers both kinds ───────────────────────
if grep -q '^  - kind: intent_overlap_detected$' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" \
   && grep -q '^  - kind: intent_overlap_overridden$' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"; then
    ok "EVENT_REGISTRY.yaml registers intent_overlap_detected + intent_overlap_overridden"
else
    fail "test 8: events not in registry"
fi

echo
echo "===== INFRA-1116 results: $PASS pass, $FAIL fail ====="
[[ $FAIL -eq 0 ]]
