#!/usr/bin/env bash
# scripts/ci/test-calibration-generic.sh — RESILIENT-974 (RESILIENT-422 slice)
#
# Proves scripts/coord/lib/calibration.sh's calibration_settle() is generic:
# usable from a "this-will-break-to-P0" call path that has NOTHING to do with
# PR-merge bets (here: a fictional incident-recall bet ledger), while still
# reproducing the exact PR-merge-bet numbers pr-book.sh relies on.
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LIB="$REPO_ROOT/scripts/coord/lib/calibration.sh"
[[ -f "$LIB" ]] || { printf 'FATAL: %s not found\n' "$LIB" >&2; exit 1; }
# shellcheck source=lib/calibration.sh
source "$LIB"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
_ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
_fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

# ── 1. non-PR-book call path: incident-recall bets, different id/price keys ──
LEDGER="$TMP/incident-ledger.jsonl"
cat > "$LEDGER" <<'J'
{"ts":"t","incident":"INC-1","confidence":0.9,"note":"first"}
{"ts":"t","incident":"INC-2","confidence":0.2,"note":"first"}
J
OMAP='{"INC-1":1,"INC-2":0}'
CALIB="$TMP/incident-calibration.log"
RES="$(calibration_settle "$LEDGER" "$OMAP" "$CALIB" incident confidence incident_recall_prediction incident_recall_calibration)"
BRIER="$(echo "$RES" | jq -r '.brier')"
[[ "$BRIER" == "0.025" ]] && _ok "generic component scores a non-PR domain (Brier=0.025)" \
  || { echo "$RES"; _fail "expected Brier=0.025, got $BRIER"; }
grep -q '"kind":"incident_recall_calibration"' "$CALIB" \
  && _ok "summary row stamped with caller-supplied kind" \
  || _fail "summary row missing caller kind"
grep -q '"incident":"INC-1"' "$CALIB" \
  && _ok "per-row id field uses caller-supplied id_key name" \
  || _fail "per-row id field missing/wrong key"

# ── 2. PR-merge-bet path still reproduces the original 0.025 canonical value ──
LEDGER2="$TMP/pr-ledger.jsonl"
cat > "$LEDGER2" <<'J'
{"ts":"t","pr":1,"sha":"x","price":0.9,"state":"CLEAN"}
{"ts":"t","pr":2,"sha":"y","price":0.2,"state":"DIRTY"}
J
CALIB2="$TMP/pr-calibration.log"
RES2="$(calibration_settle "$LEDGER2" '{"1":1,"2":0}' "$CALIB2" pr price pr_book_prediction pr_book_calibration)"
BRIER2="$(echo "$RES2" | jq -r '.brier')"
[[ "$BRIER2" == "0.025" ]] && _ok "PR-merge-bet call path unchanged (Brier=0.025)" \
  || { echo "$RES2"; _fail "expected Brier=0.025, got $BRIER2"; }

# ── 3. no-outcome-yet id is excluded, latest prediction wins ─────────────────
LEDGER3="$TMP/latest-ledger.jsonl"
cat > "$LEDGER3" <<'J'
{"ts":"t1","pr":9,"price":0.1}
{"ts":"t2","pr":9,"price":0.99}
J
RES3="$(calibration_settle "$LEDGER3" '{"9":1}' "$TMP/latest.log" pr price pr_book_prediction pr_book_calibration)"
LATEST_PRICE="$(echo "$RES3" | jq -r '.rows[0].predicted')"
[[ "$LATEST_PRICE" == "0.99" ]] && _ok "latest prediction per id wins (0.99, not 0.1)" \
  || { echo "$RES3"; _fail "expected latest price 0.99, got $LATEST_PRICE"; }

# ── 4. empty ledger: no crash, brier:null ────────────────────────────────────
: > "$TMP/empty.jsonl"
RES4="$(calibration_settle "$TMP/empty.jsonl" '{}' "$TMP/empty.log" pr price pr_book_prediction pr_book_calibration)"
[[ "$(echo "$RES4" | jq -r '.brier')" == "null" ]] && _ok "empty ledger yields brier:null, no crash" \
  || { echo "$RES4"; _fail "empty ledger did not yield brier:null"; }

echo
if [[ $FAIL -eq 0 ]]; then echo "$PASS passed, 0 failed"; exit 0
else echo "$PASS passed, $FAIL failed"; exit 1
fi
