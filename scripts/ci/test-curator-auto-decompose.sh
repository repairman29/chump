#!/usr/bin/env bash
# test-curator-auto-decompose.sh — INFRA-943
#
# Verifies curator Decision 3b: when a pillar has 0 pickable xs/s/m gaps
# AND an l/xl gap with no depends_on exists, auto-decompose fires instead of
# (or in addition to) filing a fresh tracking gap.
#
# Scenarios:
#   1. Starved pillar + l-gap present → curator_auto_decompose event emitted
#   2. Multiple starved pillars → at most 1 decompose per run (guard)
#   3. No l/xl candidate → no decompose, normal tracking gap filed
#   4. Dry-run → dry_run log, no actual decompose call made

# shellcheck disable=SC2015
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

RESERVE_COUNTER="$TMP/counter"
echo 200 > "$RESERVE_COUNTER"
DECOMPOSE_LOG="$TMP/decompose.log"

make_shims() {
  local shim_dir="$1"
  local gap_list_json="${2:-[]}"
  mkdir -p "$shim_dir"

  cat > "$shim_dir/chump" <<SHIM
#!/usr/bin/env bash
case "\$1 \$2" in
  "health --slo-check") echo "  pass L1-SLO-1 silent_agent"; exit 0 ;;
  "waste-tally --window") echo '{"waste_rate":5}'; exit 0 ;;
  "gap audit-priorities") echo '{"p0_count":0,"vague_pickable":0}'; exit 0 ;;
  "gap list")
    echo '$gap_list_json'
    exit 0 ;;
  "gap decompose")
    # Record call for inspection, then echo fake sub-gap IDs.
    echo "decompose \$3 \$4" >> "$DECOMPOSE_LOG"
    echo "filed INFRA-901 filed INFRA-902"
    exit 0 ;;
  "gap reserve")
    n=\$(cat "$RESERVE_COUNTER")
    echo \$((n + 1)) > "$RESERVE_COUNTER"
    echo "reserving ID... done INFRA-\$n"
    exit 0 ;;
  "gap set") exit 0 ;;
  *) echo "{}"; exit 0 ;;
esac
SHIM
  chmod +x "$shim_dir/chump"

  cat > "$shim_dir/gh" <<'GHSHIM'
#!/usr/bin/env bash
if [[ "$1 $2" == "pr list" ]]; then echo 0; fi
exit 0
GHSHIM
  chmod +x "$shim_dir/gh"
}

run_curator() {
  local shim_dir="$1"; shift
  env \
    PATH="$shim_dir:/usr/bin:/bin" \
    CHUMP_AMBIENT_LOG="$AMB" \
    CHUMP_FLEET_STATE="$FS" \
    LOCK_DIR="$LOCK_DIR" \
    REPO_ROOT="$REPO_ROOT" \
    HOME="$TMP" \
    "$@" \
    bash "$CURATOR" --once 2>&1
}

# ---------------------------------------------------------------------------
# Scenario 1: EFFECTIVE has 0 xs/s/m pickable gaps but 1 l-gap with no deps
# → curator_auto_decompose must appear in ambient.jsonl
# ---------------------------------------------------------------------------
: > "$AMB"
: > "$DECOMPOSE_LOG"
rm -f "$LOCK_DIR"/curator-filed-*.json

# gap list JSON: EFFECTIVE has only an l-gap, other pillars have 2 xs gaps each
GAP_LIST_JSON='[
  {"id":"INFRA-800","pillar":"EFFECTIVE","size":"l","depends_on":[],"status":"open","priority":"P1"},
  {"id":"INFRA-810","pillar":"CREDIBLE","size":"xs","depends_on":[],"status":"open","priority":"P1"},
  {"id":"INFRA-811","pillar":"CREDIBLE","size":"s","depends_on":[],"status":"open","priority":"P1"},
  {"id":"INFRA-820","pillar":"RESILIENT","size":"xs","depends_on":[],"status":"open","priority":"P1"},
  {"id":"INFRA-821","pillar":"RESILIENT","size":"m","depends_on":[],"status":"open","priority":"P1"},
  {"id":"INFRA-830","pillar":"ZERO-WASTE","size":"s","depends_on":[],"status":"open","priority":"P1"},
  {"id":"INFRA-831","pillar":"ZERO-WASTE","size":"xs","depends_on":[],"status":"open","priority":"P1"}
]'

SHIM1="$TMP/shim1"
make_shims "$SHIM1" "$GAP_LIST_JSON"
run_curator "$SHIM1" >/dev/null

grep -q '"kind":"curator_auto_decompose"' "$AMB" \
  || fail "Scenario 1: curator_auto_decompose event not emitted"
ok "Scenario 1: curator_auto_decompose event emitted for starved EFFECTIVE pillar"

grep -q '"gap_id":"INFRA-800"' "$AMB" \
  || fail "Scenario 1: wrong gap_id in curator_auto_decompose event"
ok "Scenario 1: correct gap_id INFRA-800 in event"

grep -q '"pillar":"EFFECTIVE"' "$AMB" \
  || fail "Scenario 1: pillar field missing in curator_auto_decompose event"
ok "Scenario 1: pillar field present"

DECOMPOSE_CALLS=$(wc -l < "$DECOMPOSE_LOG" | tr -d ' ')
[[ "$DECOMPOSE_CALLS" -ge 1 ]] \
  || fail "Scenario 1: chump gap decompose was not called"
ok "Scenario 1: chump gap decompose called ($DECOMPOSE_CALLS call(s))"

# ---------------------------------------------------------------------------
# Scenario 2: Two pillars both have 0 xs/s/m gaps, each with an l-gap
# → at most 1 auto-decompose per curator run (guard)
# ---------------------------------------------------------------------------
: > "$AMB"
: > "$DECOMPOSE_LOG"
rm -f "$LOCK_DIR"/curator-filed-*.json

GAP_LIST_JSON2='[
  {"id":"INFRA-800","pillar":"EFFECTIVE","size":"l","depends_on":[],"status":"open","priority":"P1"},
  {"id":"INFRA-801","pillar":"CREDIBLE","size":"xl","depends_on":[],"status":"open","priority":"P1"}
]'

SHIM2="$TMP/shim2"
make_shims "$SHIM2" "$GAP_LIST_JSON2"
run_curator "$SHIM2" >/dev/null

DECOMPOSE_CALLS2=$(wc -l < "$DECOMPOSE_LOG" | tr -d ' ')
[[ "$DECOMPOSE_CALLS2" -le 1 ]] \
  || fail "Scenario 2: more than 1 decompose called per run (guard broken), got $DECOMPOSE_CALLS2"
ok "Scenario 2: at most 1 auto-decompose per run (got $DECOMPOSE_CALLS2)"

AUTO_EVENTS=$(grep -c '"kind":"curator_auto_decompose"' "$AMB" || true)
[[ "$AUTO_EVENTS" -le 1 ]] \
  || fail "Scenario 2: more than 1 curator_auto_decompose event emitted, got $AUTO_EVENTS"
ok "Scenario 2: at most 1 curator_auto_decompose event per run"

# ---------------------------------------------------------------------------
# Scenario 3: Starved pillar but NO l/xl candidate (only blocked xs gap)
# → no decompose, falls back to filing tracking gap
# ---------------------------------------------------------------------------
: > "$AMB"
: > "$DECOMPOSE_LOG"
rm -f "$LOCK_DIR"/curator-filed-*.json

GAP_LIST_JSON3='[
  {"id":"INFRA-850","pillar":"EFFECTIVE","size":"xs","depends_on":["INFRA-999"],"status":"open","priority":"P1"}
]'

SHIM3="$TMP/shim3"
make_shims "$SHIM3" "$GAP_LIST_JSON3"
run_curator "$SHIM3" >/dev/null

grep -qv '"kind":"curator_auto_decompose"' "$AMB" || true
DECOMPOSE_CALLS3=$(wc -l < "$DECOMPOSE_LOG" | tr -d ' ')
[[ "$DECOMPOSE_CALLS3" -eq 0 ]] \
  || fail "Scenario 3: decompose called when no valid l/xl candidate exists"
ok "Scenario 3: no decompose when only blocked/no l/xl candidate"

BALANCE_FILED=$(grep '"decision_type":"balance_restock"' "$AMB" | grep -c '"action_taken":"filed INFRA-' || true)
[[ "$BALANCE_FILED" -ge 1 ]] \
  || fail "Scenario 3: tracking gap not filed when decompose unavailable"
ok "Scenario 3: tracking gap filed as fallback"

# ---------------------------------------------------------------------------
# Scenario 4: dry-run — no actual decompose call, dry_run event logged
# ---------------------------------------------------------------------------
: > "$AMB"
: > "$DECOMPOSE_LOG"
rm -f "$LOCK_DIR"/curator-filed-*.json

SHIM4="$TMP/shim4"
make_shims "$SHIM4" "$GAP_LIST_JSON"
env \
  PATH="$SHIM4:/usr/bin:/bin" \
  CHUMP_AMBIENT_LOG="$AMB" \
  CHUMP_FLEET_STATE="$FS" \
  LOCK_DIR="$LOCK_DIR" \
  REPO_ROOT="$REPO_ROOT" \
  HOME="$TMP" \
  CHUMP_CURATOR_DRY_RUN=1 \
  bash "$CURATOR" --once --dry-run >/dev/null 2>&1

DECOMPOSE_CALLS4=$(wc -l < "$DECOMPOSE_LOG" | tr -d ' ')
[[ "$DECOMPOSE_CALLS4" -eq 0 ]] \
  || fail "Scenario 4: dry-run still called decompose ($DECOMPOSE_CALLS4 times)"
ok "Scenario 4: dry-run did not call chump gap decompose"

grep -q '"action_taken":"dry_run: would call chump gap decompose INFRA-800 --apply"' "$AMB" \
  || fail "Scenario 4: dry-run did not emit correct dry_run action_taken"
ok "Scenario 4: dry-run emits dry_run action_taken"

# ---------------------------------------------------------------------------
# Scenario 5: l-gap has depends_on → not eligible, no decompose
# ---------------------------------------------------------------------------
: > "$AMB"
: > "$DECOMPOSE_LOG"
rm -f "$LOCK_DIR"/curator-filed-*.json

GAP_LIST_JSON5='[
  {"id":"INFRA-860","pillar":"EFFECTIVE","size":"l","depends_on":["INFRA-999"],"status":"open","priority":"P1"}
]'

SHIM5="$TMP/shim5"
make_shims "$SHIM5" "$GAP_LIST_JSON5"
run_curator "$SHIM5" >/dev/null

DECOMPOSE_CALLS5=$(wc -l < "$DECOMPOSE_LOG" | tr -d ' ')
[[ "$DECOMPOSE_CALLS5" -eq 0 ]] \
  || fail "Scenario 5: decomposed a blocked l-gap (has depends_on)"
ok "Scenario 5: blocked l-gap not decomposed"

echo
echo "=== test-curator-auto-decompose.sh PASSED (5/5 scenarios) ==="
