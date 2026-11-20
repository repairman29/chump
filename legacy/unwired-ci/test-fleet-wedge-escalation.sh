#!/usr/bin/env bash
# test-fleet-wedge-escalation.sh — INFRA-845
#
# Exercises scripts/coord/fleet-wedge-handler.sh against synthetic
# ambient.jsonl + fleet-state.json fixtures.
#
# Scenarios:
#   1. Fresh wedge: handler emits fleet_scale_change, sets wedged=true.
#   2. Persistent wedge past escalate threshold: emits fleet_wedge_escalated,
#      writes incident doc, sets wedge_escalated=true.
#   3. Clean state after quiet window: emits fleet_wedge_resolved.
#   4. CHUMP_PAGER_WEBHOOK set: pager_notified event emitted.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

HANDLER="$REPO_ROOT/scripts/coord/fleet-wedge-handler.sh"
[[ -x "$HANDLER" ]] || { echo "FAIL: $HANDLER not executable"; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
AMB="$TMP/ambient.jsonl"
FS="$TMP/fleet-state.json"

# Helper: seed a fleet_wedge event at a relative timestamp (seconds-ago).
seed_wedge() {
  local ago_s="$1"
  local ts; ts="$(python3 -c "import datetime; print((datetime.datetime.utcnow()-datetime.timedelta(seconds=$ago_s)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
  printf '{"ts":"%s","kind":"fleet_wedge","agent_id":"test"}\n' "$ts" >> "$AMB"
}

reset_state() {
  echo '{"wedged":false,"wedge_start":"","wedge_escalated":false}' > "$FS"
  : > "$AMB"
}

run_handler() {
  env \
    CHUMP_AMBIENT_LOG="$AMB" \
    CHUMP_FLEET_STATE="$FS" \
    CHUMP_WEDGE_DRY_RUN=1 \
    REPO_ROOT="$REPO_ROOT" \
    "$@" \
    bash "$HANDLER" 2>&1
}

# ── Scenario 1: fresh wedge ──────────────────────────────────────────────────
reset_state
seed_wedge 60
out=$(run_handler)
echo "$out" | grep -q "scaling down" || fail "fresh wedge: handler did not announce scale-down"
grep -q '"kind":"fleet_scale_change"' "$AMB" || fail "fresh wedge: fleet_scale_change not emitted"
ok "scenario 1: fresh wedge → scale-down emitted"

# ── Scenario 2: persistent wedge → escalation ────────────────────────────────
# Seed wedge 2000s ago, mark fleet state as already-wedged from same time.
reset_state
seed_wedge 2000
ts="$(python3 -c "import datetime; print((datetime.datetime.utcnow()-datetime.timedelta(seconds=2000)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
echo "{\"wedged\":true,\"wedge_start\":\"$ts\",\"wedge_escalated\":false}" > "$FS"
out=$(run_handler CHUMP_WEDGE_ESCALATE_S=1800)
echo "$out" | grep -q "escalating" || fail "persistent wedge: handler did not escalate (out: $out)"
grep -q '"kind":"fleet_wedge_escalated"' "$AMB" \
  || fail "persistent wedge: fleet_wedge_escalated not emitted"
echo "$out" | grep -q "dry-run.*incident" || fail "persistent wedge: incident doc path not announced"
ok "scenario 2: persistent wedge → escalation emitted"

# ── Scenario 3: clean state after quiet window ───────────────────────────────
# Wedge state set but last event was long ago (5000s) → should resolve.
reset_state
seed_wedge 5000
ts="$(python3 -c "import datetime; print((datetime.datetime.utcnow()-datetime.timedelta(seconds=5000)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
echo "{\"wedged\":true,\"wedge_start\":\"$ts\",\"wedge_escalated\":true}" > "$FS"
out=$(run_handler CHUMP_WEDGE_CLEAR_S=1800)
echo "$out" | grep -q "resolving" || fail "quiet window: handler did not resolve (out: $out)"
grep -q '"kind":"fleet_wedge_resolved"' "$AMB" \
  || fail "quiet window: fleet_wedge_resolved not emitted"
ok "scenario 3: quiet window → resolution emitted"

# ── Scenario 4: pager webhook (dry-run mode does not POST) ───────────────────
reset_state
seed_wedge 2000
ts="$(python3 -c "import datetime; print((datetime.datetime.utcnow()-datetime.timedelta(seconds=2000)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
echo "{\"wedged\":true,\"wedge_start\":\"$ts\",\"wedge_escalated\":false}" > "$FS"
out=$(run_handler CHUMP_WEDGE_ESCALATE_S=1800 CHUMP_PAGER_WEBHOOK=https://example.invalid/hook)
echo "$out" | grep -q "would POST" || fail "pager: webhook dry-run path did not fire"
ok "scenario 4: pager webhook respected in dry-run"

# ── Scenario 5: no wedges + no state → no-op ─────────────────────────────────
reset_state
out=$(run_handler)
echo "$out" | grep -q "clean" || fail "no-op: handler should report clean state"
ok "scenario 5: clean state → no-op"

echo
echo "=== test-fleet-wedge-escalation.sh PASSED ==="
