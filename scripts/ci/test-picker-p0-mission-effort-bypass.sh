#!/usr/bin/env bash
# MISSION-047 regression guard.
#
# A P0 + domain=MISSION gap with effort>=m was silently dropped by every haiku
# worker: the model-class effort gate in both pickers had
#     if worker_model == "haiku" and e in ("m","l","xl"): continue
# with NO _is_p0_mission bypass (the symmetric sonnet-xs gate right below it DID
# bypass). Since routing/default makes workers haiku, such P0-MISSION gaps
# starved forever — the literal mechanism of MISSION-026 (MISSION-046 was the
# live victim: P0/m, skipped while the fleet picked P1/xs gaps).
#
# Cure: add `and not _is_p0_mission` to the haiku m/l/xl gate in BOTH pickers.
# This test asserts (a) the bypass is present in both, and (b) _pick_gap.py (the
# canonical ranker, no claim side-effect) now INCLUDES a P0-MISSION/m gap for a
# haiku worker while still EXCLUDING a non-mission P1/m gap (no regression).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # scripts/
PICK="$ROOT/dispatch/_pick_gap.py"
PICK_CLAIM="$ROOT/dispatch/_pick_and_claim_gap.py"
[[ -f "$PICK" && -f "$PICK_CLAIM" ]] || { echo "FAIL: picker scripts not found"; exit 1; }

fails=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; fails=$((fails+1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/cooldown"

# (a) Static: both pickers bypass the haiku m/l/xl gate for P0-MISSION gaps.
for f in "$PICK" "$PICK_CLAIM"; do
  if grep -q 'haiku" and e in ("m", "l", "xl") and not _is_p0_mission' "$f"; then
    ok "$(basename "$f"): haiku m/l/xl gate bypasses P0-MISSION"
  else
    fail "$(basename "$f"): haiku gate MISSING the _is_p0_mission bypass"
  fi
done

run_pick() {  # $1=gap_json_file
  GAP_JSON_FILE="$1" \
  FLEET_MODEL=haiku \
  FLEET_PRIORITY_FILTER='P0,P1' \
  FLEET_EFFORT_FILTER='xs,s,m' \
  FLEET_DOMAIN_FILTER='' \
  EXCLUDE_RE='^$' \
  ACTIVE_GAPS='' \
  COOLDOWN_DIR="$tmp/cooldown" \
  WORKER_INDEX=1 WORKER_ID=1 \
  python3 "$PICK" 2>/dev/null
}

# (b1) A haiku worker MUST now pick a P0-MISSION effort=m gap (the bypass).
#      The P1/INFRA effort=m gap is correctly filtered out for haiku, leaving the
#      P0-MISSION gap as the only candidate.
cat > "$tmp/gaps1.json" <<'JSON'
[
 {"id":"MISSION-9001","priority":"P0","domain":"MISSION","effort":"m","title":"MISSION: bypass test","depends_on":"[]","skills_required":"","required_model":"","created_at":1000,"status":"open","acceptance_criteria":"the picker includes this gap for a haiku worker"},
 {"id":"INFRA-9002","priority":"P1","domain":"INFRA","effort":"m","title":"INFRA: haiku should skip","depends_on":"[]","skills_required":"","required_model":"","created_at":2000,"status":"open","acceptance_criteria":"non-mission P1 m gap, haiku must skip it"}
]
JSON
got="$(run_pick "$tmp/gaps1.json")"
[[ "$got" == "MISSION-9001" ]] \
  && ok "haiku worker PICKS the P0-MISSION effort=m gap (bypass works)" \
  || fail "haiku picked '$got' (expected MISSION-9001 — bypass not effective)"

# (b2) No regression: a haiku worker must still SKIP a non-mission P1 effort=m gap.
cat > "$tmp/gaps2.json" <<'JSON'
[
 {"id":"INFRA-9003","priority":"P1","domain":"INFRA","effort":"m","title":"INFRA: P1 m, haiku must skip","depends_on":"[]","skills_required":"","required_model":"","created_at":1000,"status":"open","acceptance_criteria":"non-mission P1 m gap, haiku must skip it"}
]
JSON
got2="$(run_pick "$tmp/gaps2.json")"
[[ -z "$got2" ]] \
  && ok "haiku worker still SKIPS a non-mission P1 effort=m gap (no regression)" \
  || fail "haiku picked '$got2' (a P1/m gap should be excluded for haiku)"

echo ""
if [[ "$fails" -eq 0 ]]; then
  echo "PASS: test-picker-p0-mission-effort-bypass.sh (P0-MISSION gaps no longer starve under haiku)"
  exit 0
else
  echo "FAIL: test-picker-p0-mission-effort-bypass.sh ($fails assertion(s) failed)"
  exit 1
fi
