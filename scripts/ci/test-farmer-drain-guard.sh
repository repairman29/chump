#!/usr/bin/env bash
# scripts/ci/test-farmer-drain-guard.sh — RESILIENT-076
#
# Guards the farmer's drain-guardian. The dangerous part is the ruleset
# auto-reconcile (it PUTs a repo ruleset via the API), so the invariants that
# matter are: (a) on DRIFT it reconciles strict->baseline with a writable-only PUT
# body; (b) when the fleet is PAUSED (.chump/fleet-paused) it NEVER mutates; (c)
# when already in-sync it does NOT churn. Tested hermetically with a mock `gh` —
# no live GitHub calls.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 2
GUARD="scripts/dev/farmer-drain-guard.sh"
FARMER="scripts/dev/farmer-brown.sh"
P=0; F=0
p(){ echo "[PASS] $1"; P=$((P+1)); }
f(){ echo "[FAIL] $1"; F=$((F+1)); }

echo "=== test-farmer-drain-guard.sh (RESILIENT-076) ==="

# 1. both scripts parse
bash -n "$GUARD" 2>/dev/null && p "farmer-drain-guard.sh parses" || f "guard FAILS bash -n"
bash -n "$FARMER" 2>/dev/null && p "farmer-brown.sh parses" || f "farmer-brown.sh FAILS bash -n"

# 2. farmer-brown wires the guard into its tick
grep -q 'farmer-drain-guard.sh' "$FARMER" && p "farmer-brown.sh calls the drain-guard each tick" || f "farmer-brown.sh does NOT call the drain-guard"

# 3. kill-switch gate + scanner-anchor + backup present (static safety)
grep -q 'fleet-paused' "$GUARD" && p "kill-switch gate present (.chump/fleet-paused)" || f "no kill-switch gate"
grep -q 'scanner-anchor.*farmer_drain_guard' "$GUARD" && p "ambient kind has scanner-anchor (registry-safe)" || f "missing scanner-anchor for farmer_drain_guard"
grep -q 'ruleset_backup_' "$GUARD" && p "backs up the ruleset before PUT" || f "no pre-PUT backup"

# --- hermetic behavioral tests with a mock gh ---
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
PUTLOG="$TMP/put_body.json"; CALLLOG="$TMP/calls.log"
# Mock gh: GET returns a canned ruleset (strict configurable via $TMP/strict);
# PUT records the stdin body + logs the call.
cat > "$BIN/gh" <<MOCK
#!/usr/bin/env bash
echo "\$*" >> "$CALLLOG"
strict="\$(cat "$TMP/strict" 2>/dev/null || echo true)"
if printf '%s' "\$*" | grep -q -- '-X PUT'; then
  cat > "$PUTLOG"   # capture the PUT body from stdin
  echo '{"id":15133729}'; exit 0
fi
# GET ruleset
cat <<JSON
{"id":15133729,"name":"Protect main","target":"branch","enforcement":"active",
 "node_id":"RRS_x","created_at":"2024-01-01","updated_at":"2024-01-02",
 "source":"repairman29/chump","source_type":"Repository","_links":{"self":{"href":"x"}},
 "current_user_can_bypass":"always","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},
 "rules":[{"type":"non_fast_forward"},
          {"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":\${strict},"required_status_checks":[{"context":"test"}]}}]}
JSON
MOCK
chmod +x "$BIN/gh"

# A baseline that wants strict=false, in a temp root.
TROOT="$TMP/root"; mkdir -p "$TROOT/docs/baselines" "$TROOT/.chump" "$TROOT/.chump-locks"
echo '{"_ruleset_baseline":{"ruleset_id":15133729,"strict_required_status_checks_policy":false}}' > "$TROOT/docs/baselines/branch-protection-main.json"

run_guard(){  # $1=strict-live  $2=paused(1/0)  -> sets PUTLOG/CALLLOG
  : > "$CALLLOG"; rm -f "$PUTLOG"
  echo "$1" > "$TMP/strict"
  [ "$2" = "1" ] && touch "$TROOT/.chump/fleet-paused" || rm -f "$TROOT/.chump/fleet-paused"
  ( unset CI; PATH="$BIN:$PATH" CHUMP_REPO_ROOT="$TROOT" CHUMP_AMBIENT_LOG="$TROOT/.chump-locks/ambient.jsonl" \
      bash -c '
        cd "'"$TROOT"'"
        source "'"$ROOT/$GUARD"'"
        # force the temp root (no git here so _FDG_ROOT falls back to CHUMP_REPO_ROOT)
        BASELINE="'"$TROOT"'/docs/baselines/branch-protection-main.json"
        PAUSED_MARKER="'"$TROOT"'/.chump/fleet-paused"
        AMBIENT="'"$TROOT"'/.chump-locks/ambient.jsonl"
        fdg_guard_ruleset
      ' >/dev/null 2>&1 )
}

# B. DRIFT + active -> reconciles: PUT called, body strict=false, only writable keys.
run_guard true 0
if [ -f "$PUTLOG" ] && python3 -c "
import json,sys
b=json.load(open('$PUTLOG'))
ok = set(b.keys()) <= {'name','target','enforcement','conditions','rules','bypass_actors'}
strict=[r for r in b['rules'] if r['type']=='required_status_checks'][0]['parameters']['strict_required_status_checks_policy']
sys.exit(0 if (ok and strict is False and 'id' not in b and 'source' not in b) else 1)
" 2>/dev/null; then p "drift+active: reconciled (PUT body strict=false, read-only fields stripped)"; else f "drift+active did NOT produce a correct writable-only strict=false PUT"; fi

# C. DRIFT + paused -> NEVER PUTs.
run_guard true 1
if [ ! -f "$PUTLOG" ] && ! grep -q -- '-X PUT' "$CALLLOG"; then p "drift+paused: NO mutation (kill switch honored)"; else f "drift+paused MUTATED — kill switch ignored (UNSAFE)"; fi

# D. in-sync (live strict=false) -> no churn.
run_guard false 0
if [ ! -f "$PUTLOG" ]; then p "in-sync: no needless PUT"; else f "in-sync churned a PUT"; fi

echo ""
echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ] || exit 1
