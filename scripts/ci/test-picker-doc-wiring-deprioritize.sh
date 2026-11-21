#!/usr/bin/env bash
# test-picker-doc-wiring-deprioritize.sh — INFRA-8068
# Owned-worker picker: excludes the EFFECTIVE "Wire X into curator-opus-<role>"
# doc-wiring family and ranks outcome-linked gaps above un-outcomed ones.
set -uo pipefail
PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CANON="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"
TMP="$(mktemp -d -t doc-wiring.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.chump-locks"

run_list() {
    GAP_JSON_FILE="$1" CHUMP_ACTIVE_MISSION=MISSION-010 CHUMP_REPO="$TMP" \
    CHUMP_AMBIENT_LOG="$TMP/.chump-locks/ambient.jsonl" CHUMP_REBALANCE=0 \
    FLEET_MODEL=sonnet WORKER_INDEX=1 WORKER_ID=doc-wiring-test \
      python3 "$CANON" --list
}

cat > "$TMP/store.json" <<'JSON'
[
  {"id":"EFFECTIVE-106","domain":"EFFECTIVE","priority":"P1","effort":"xs","status":"open",
   "created_at":1,"depends_on":"[]","acceptance_criteria":"[\"1. linked.\"]",
   "title":"EFFECTIVE-106: Wire scripts/x.sh into curator-opus-ci-audit","outcome_id":null,"notes":"","description":""},
  {"id":"INFRA-PLAIN","domain":"INFRA","priority":"P1","effort":"s","status":"open",
   "created_at":2,"depends_on":"[]","acceptance_criteria":"[\"1. thing.\"]",
   "title":"Plain gap, no outcome","outcome_id":null,"notes":"","description":""},
  {"id":"INFRA-OUTCOME","domain":"INFRA","priority":"P1","effort":"s","status":"open",
   "created_at":3,"depends_on":"[]","acceptance_criteria":"[\"1. thing.\"]",
   "title":"Gap with outcome","outcome_id":"OUT-7","notes":"","description":""}
]
JSON

out="$(run_list "$TMP/store.json")"
if grep -q EFFECTIVE-106 <<<"$out"; then fail "doc-wiring family not excluded: $out"; else ok "doc-wiring family excluded"; fi
if [[ "$(head -1 <<<"$out")" == "INFRA-OUTCOME" ]]; then ok "outcome-linked outranks un-outcomed (despite being newer)"; else fail "ranking wrong: $out"; fi

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
