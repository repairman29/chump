#!/usr/bin/env bash
# test-slo-breach-dedupe.sh — INFRA-955
#
# Asserts the edge-emission behavior of audit_slo() in opus-curator.sh:
#   1. Healthy → healthy: nothing emitted.
#   2. Healthy → breach: emit slo_breach with slo_name + detail.
#   3. Breach → same breach: NOTHING re-emitted (the dedupe behavior).
#   4. Breach → different breach: emit a fresh slo_breach.
#   5. Breach → healthy: emit slo_recovered.
#   6. Existing slo_breach EVENT_REGISTRY entry still parses.
#
# We test audit_slo() in isolation by stubbing `chump health --slo-check`
# output via a shim on PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CURATOR="$REPO_ROOT/scripts/coord/opus-curator.sh"
[[ -f "$CURATOR" ]] || { echo "FAIL: missing $CURATOR"; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOCK_DIR="$TMP/.chump-locks"
mkdir -p "$LOCK_DIR"
AMB="$LOCK_DIR/ambient.jsonl"
FS="$LOCK_DIR/fleet-state.json"
echo '{}' > "$FS"

# Build a shim `chump` that prints whatever the caller put in $TMP/slo.txt.
SHIM_DIR="$TMP/bin"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/chump" <<'EOF'
#!/usr/bin/env bash
# Test shim — only handles `chump health --slo-check`.
if [[ "$1" == "health" && "$2" == "--slo-check" ]]; then
  cat "${CHUMP_TEST_SLO_FIXTURE:-/dev/null}"
  # Exit 0 if no BREACH lines, 1 otherwise.
  if grep -q '✗ BREACH' "${CHUMP_TEST_SLO_FIXTURE:-/dev/null}" 2>/dev/null; then
    exit 1
  fi
  exit 0
fi
echo "shim: unknown args: $*" >&2; exit 99
EOF
chmod +x "$SHIM_DIR/chump"

# Extract audit_slo() body once, save to a sourcable file. Stub the
# helpers it depends on (fleet_state_set_field, log_ambient).
AUDIT_FN="$TMP/audit_slo_extracted.sh"
{
  echo 'AMBIENT="$CHUMP_AMBIENT_LOG"'
  echo 'FLEET_STATE="$CHUMP_FLEET_STATE"'
  cat <<'STUBS'
fleet_state_set_field() {
  local k="$1" v="$2"
  if command -v jq &>/dev/null; then
    local tmp; tmp=$(mktemp)
    jq --arg k "$k" --arg v "$v" '.[$k] = $v' "$FLEET_STATE" > "$tmp" && mv "$tmp" "$FLEET_STATE"
  fi
}
log_ambient() {
  local kind="$1" data="$2"
  printf '{"ts":"%s","kind":"%s",%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$data" >> "$AMBIENT"
}
STUBS
  sed -n '/^audit_slo() {/,/^}$/p' "$CURATOR"
  echo 'audit_slo'
} > "$AUDIT_FN"

run_audit() {
  local fixture="$1"
  cp "$fixture" "$TMP/slo.txt"
  env \
    PATH="$SHIM_DIR:$PATH" \
    CHUMP_TEST_SLO_FIXTURE="$TMP/slo.txt" \
    CHUMP_AMBIENT_LOG="$AMB" \
    CHUMP_FLEET_STATE="$FS" \
    REPO_ROOT="$REPO_ROOT" \
    bash "$AUDIT_FN"
}

# Fixture 1: healthy
cat > "$TMP/healthy.txt" <<'EOF'
═══ Fleet SLO Check ═══
  ✓ pass    L1-SLO-1  [0]  silent_agent = 0/week
  ✓ pass    L2-SLO-4  [4 over target]  pillar balance ≥ 2 pickable each
EOF

# Fixture 2: breach on L2-SLO-4
cat > "$TMP/breach_a.txt" <<'EOF'
═══ Fleet SLO Check ═══
  ✓ pass    L1-SLO-1  [0]  silent_agent = 0/week
  ✗ BREACH  L2-SLO-4  [4 under target]  pillar balance ≥ 2 pickable each
EOF

# Fixture 3: breach on L1-SLO-3 only (different SLO)
cat > "$TMP/breach_b.txt" <<'EOF'
═══ Fleet SLO Check ═══
  ✗ BREACH  L1-SLO-3  [82%]  auto-restart success > 95%
  ✓ pass    L2-SLO-4  [4 over target]  pillar balance ≥ 2 pickable each
EOF

# Scenario 1: healthy → healthy → no emissions.
: > "$AMB"; echo '{}' > "$FS"
run_audit "$TMP/healthy.txt" >/dev/null 2>&1 || true
run_audit "$TMP/healthy.txt" >/dev/null 2>&1 || true
[[ ! -s "$AMB" ]] || fail "scenario 1: healthy→healthy should emit nothing (got: $(cat $AMB))"
ok "scenario 1: healthy → healthy → silent"

# Scenario 2: healthy → breach → emits slo_breach with name.
: > "$AMB"; echo '{}' > "$FS"
run_audit "$TMP/breach_a.txt" >/dev/null 2>&1 || true
grep -q '"kind":"slo_breach"' "$AMB" || fail "scenario 2: slo_breach not emitted"
grep -q '"slo_name":"L2-SLO-4"' "$AMB" || fail "scenario 2: slo_name field missing/wrong"
ok "scenario 2: healthy → breach → slo_breach emitted with slo_name"

# Scenario 3: same breach again → suppressed.
EVENTS_BEFORE=$(wc -l < "$AMB")
run_audit "$TMP/breach_a.txt" >/dev/null 2>&1 || true
EVENTS_AFTER=$(wc -l < "$AMB")
if [[ "$EVENTS_AFTER" -ne "$EVENTS_BEFORE" ]]; then
  fail "scenario 3: identical re-breach should be silent (before=$EVENTS_BEFORE, after=$EVENTS_AFTER)"
fi
ok "scenario 3: continuous breach → no re-emit (dedupe)"

# Scenario 4: different breach → fresh emission with new slo_name.
run_audit "$TMP/breach_b.txt" >/dev/null 2>&1 || true
grep -q '"slo_name":"L1-SLO-3"' "$AMB" || fail "scenario 4: new slo_name not emitted"
ok "scenario 4: changed breach set → fresh slo_breach emitted"

# Scenario 5: breach → healthy → slo_recovered.
run_audit "$TMP/healthy.txt" >/dev/null 2>&1 || true
grep -q '"kind":"slo_recovered"' "$AMB" || fail "scenario 5: slo_recovered not emitted"
ok "scenario 5: breach → healthy → slo_recovered emitted"

# Scenario 6: registry entry parses (just exist-check; full schema test is INFRA-754).
grep -q '^  - kind: slo_recovered' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" \
  || fail "scenario 6: slo_recovered missing from EVENT_REGISTRY.yaml"
ok "scenario 6: slo_recovered registered"

echo
echo "=== test-slo-breach-dedupe.sh PASSED ==="
