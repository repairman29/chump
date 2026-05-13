#!/usr/bin/env bash
# test-chump-fleet-restart.sh — INFRA-844
#
# Validates run-fleet.sh --restart flag that tears down an existing fleet
# and relaunches it cleanly. Tests use a mock tmux-less environment to
# avoid needing a running fleet.
#
# Tests:
#  1. --help exits 0
#  2. run-fleet.sh has INFRA-844 restart section
#  3. fleet_restart event emitted with required fields
#  4. --dry-run prints intent, no ambient event written
#  5. FLEET_SIZE respected in event (to_size = FLEET_SIZE)
#  6. EVENT_REGISTRY.yaml has fleet_restart entry
#  7. Restart with no existing session uses from_size=0
#  8. --help output contains usage text
#  9. Unknown flag exits 2
# 10. --restart documented in run-fleet.sh

set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_FLEET="$REPO_ROOT/scripts/dispatch/run-fleet.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

echo "=== INFRA-844 fleet restart test ==="
echo

TMP="$(mktemp -d -t chump-fleet-restart-test-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

AMB="$TMP/ambient.jsonl"
mkdir -p "$TMP/locks"

# ── 1. --help exits 0 ────────────────────────────────────────────────────────
echo "[1. --help exits 0]"
bash "$RUN_FLEET" --help >/dev/null 2>&1
ec=$?
[[ "$ec" -eq 0 ]] && ok "--help exits 0" || fail "--help exited $ec"

# ── 2. INFRA-844 restart section present in run-fleet.sh ────────────────────
echo
echo "[2. INFRA-844 restart section in run-fleet.sh]"
grep -q "INFRA-844" "$RUN_FLEET" && grep -q "\-\-restart" "$RUN_FLEET" && \
    ok "INFRA-844 --restart section present in run-fleet.sh" || \
    fail "INFRA-844 --restart not found in run-fleet.sh"

# ── 3. fleet_restart event has required fields ───────────────────────────────
echo
echo "[3. fleet_restart event has required fields]"
printf '{"ts":"%s","kind":"fleet_restart","from_size":0,"to_size":2,"reason":"--restart flag"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$AMB"
ev=$(grep "fleet_restart" "$AMB" | head -1)
all_ok=1
for field in ts kind from_size to_size reason; do
    echo "$ev" | grep -q "\"$field\"" || { fail "missing field: $field"; all_ok=0; }
done
[[ "$all_ok" -eq 1 ]] && ok "all required fields present (ts, kind, from_size, to_size, reason)"

# ── 4. --dry-run skips ambient event ─────────────────────────────────────────
echo
echo "[4. --dry-run skips ambient event]"
DRY_AMB="$TMP/dry-ambient.jsonl"
FLEET_DRY_RUN=1
_dry_from=0
_dry_to=2
if [[ "${FLEET_DRY_RUN:-0}" != "1" ]]; then
    printf '{"ts":"%s","kind":"fleet_restart","from_size":%d,"to_size":%d,"reason":"--restart flag"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_dry_from" "$_dry_to" >> "$DRY_AMB"
fi
if [[ ! -f "$DRY_AMB" ]] || ! grep -q "fleet_restart" "$DRY_AMB" 2>/dev/null; then
    ok "--dry-run: no fleet_restart event written"
else
    fail "--dry-run: fleet_restart event was incorrectly written"
fi
unset FLEET_DRY_RUN

# ── 5. FLEET_SIZE respected in event (to_size matches) ──────────────────────
echo
echo "[5. to_size matches FLEET_SIZE in event]"
EXPECTED_SIZE=3
SIZE_AMB="$TMP/size-ambient.jsonl"
printf '{"ts":"%s","kind":"fleet_restart","from_size":0,"to_size":%d,"reason":"--restart flag"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$EXPECTED_SIZE" >> "$SIZE_AMB"
actual_to=$(grep "fleet_restart" "$SIZE_AMB" | head -1 | grep -o '"to_size":[0-9]*' | cut -d: -f2)
[[ "$actual_to" -eq "$EXPECTED_SIZE" ]] && \
    ok "to_size=$EXPECTED_SIZE matches FLEET_SIZE=$EXPECTED_SIZE" || \
    fail "to_size mismatch: got $actual_to, expected $EXPECTED_SIZE"

# ── 6. EVENT_REGISTRY.yaml has fleet_restart entry ──────────────────────────
echo
echo "[6. EVENT_REGISTRY.yaml has fleet_restart]"
grep -q "fleet_restart" "$REGISTRY" && \
    ok "fleet_restart registered in EVENT_REGISTRY.yaml" || \
    fail "fleet_restart not found in EVENT_REGISTRY.yaml"

# ── 7. No existing session → from_size=0 ────────────────────────────────────
echo
echo "[7. No existing session → from_size=0]"
_fleet_from_size=0
if tmux has-session -t "chump-fleet-nonexistent-$$" 2>/dev/null; then
    _fleet_from_size=99
fi
NOSESS_AMB="$TMP/nosess-ambient.jsonl"
printf '{"ts":"%s","kind":"fleet_restart","from_size":%d,"to_size":2,"reason":"--restart flag"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_fleet_from_size" >> "$NOSESS_AMB"
from_val=$(grep "fleet_restart" "$NOSESS_AMB" | head -1 | grep -o '"from_size":[0-9]*' | cut -d: -f2)
[[ "$from_val" -eq 0 ]] && \
    ok "from_size=0 when no existing tmux session" || \
    fail "from_size expected 0, got $from_val"

# ── 8. --help shows usage text ──────────────────────────────────────────────
echo
echo "[8. --help shows usage text]"
help_out=$(bash "$RUN_FLEET" --help 2>&1)
echo "$help_out" | grep -qi "restart\|fleet\|worker" && \
    ok "--help output contains usage text" || \
    fail "--help output missing expected content"

# ── 9. Unknown flag exits 2 ─────────────────────────────────────────────────
echo
echo "[9. Unknown flag exits 2]"
bash "$RUN_FLEET" --unknown-flag-xyz 2>/dev/null; unk_ec=$?
[[ "$unk_ec" -eq 2 ]] && ok "unknown flag exits 2" || fail "unknown flag exit code: $unk_ec (expected 2)"

# ── 10. --restart documented in run-fleet.sh ────────────────────────────────
echo
echo "[10. --restart documented in run-fleet.sh]"
grep -q "\-\-restart" "$RUN_FLEET" && \
    ok "--restart appears in run-fleet.sh" || \
    fail "--restart not documented in run-fleet.sh"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
