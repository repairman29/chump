#!/usr/bin/env bash
# test-pr-book.sh — offline, fixture-driven coverage for scripts/coord/pr-book.sh.
# DEPTH: happy-path + edge (render formatting, Brier math, ambient emit, empty ledger).
# GAPS: does not hit the live gh API (outcomes/board are fixture-injected); does not
# assert the pr-book-model.jq pricing values themselves (covered by the model's own
# thresholds) — only that the shell wiring renders/settles/emits correctly.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$DIR/../.." && pwd)"
SCRIPT="$ROOT/scripts/coord/pr-book.sh"
TMP="$(mktemp -d "${TMPDIR:-$HOME/.chump}/prbook-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail=0; pass(){ echo "  ok: $1"; }; bad(){ echo "  FAIL: $1"; fail=1; }

# ── board render: rows must print as integer percents, no awk/bc breakage ─────
cat > "$TMP/raw.json" <<'J'
[{"number":101,"title":"clean one","mergeStateStatus":"CLEAN","createdAt":"2026-08-22T00:00:00Z","isDraft":false,"statusCheckRollup":[],"headRefOid":"aaa"},
 {"number":102,"title":"dirty red","mergeStateStatus":"DIRTY","createdAt":"2026-08-01T00:00:00Z","isDraft":false,"statusCheckRollup":[{"conclusion":"FAILURE","name":"test"}],"headRefOid":"bbb"}]
J
OUT="$(PR_BOOK_LEDGER="$TMP/led.jsonl" PR_BOOK_CALIB="$TMP/cal.log" \
       CHUMP_AMBIENT_LOG="$TMP/amb.jsonl" PR_BOOK_RAW_FIXTURE="$TMP/raw.json" \
       bash "$SCRIPT" 2>&1)"
echo "$OUT" | grep -q "invalid number" && bad "board: printf invalid-number regression" || pass "board: no invalid-number error"
echo "$OUT" | grep -qE '#101 +92%' && pass "board: clean PR priced 92% row printed" || { echo "$OUT"; bad "board: 92% row missing"; }
echo "$OUT" | grep -qE '#102 +[0-9]+%' && pass "board: dirty PR row printed with % " || bad "board: dirty row missing"
echo "$OUT" | grep -qE '^\s*-- EV [0-9]' && pass "board: EV line printed" || bad "board: EV line missing"

# ── ledger + ambient odds emitted ─────────────────────────────────────────────
[[ -s "$TMP/led.jsonl" ]] && pass "ledger: predictions appended" || bad "ledger: empty"
grep -q '"kind":"pr_book_odds"' "$TMP/amb.jsonl" 2>/dev/null && pass "ambient: pr_book_odds emitted" || bad "ambient: no pr_book_odds"
grep -q '"bands":{"lock"' "$TMP/amb.jsonl" 2>/dev/null && pass "ambient: bands present" || bad "ambient: bands missing"

# ── settle: Brier over a known ledger + outcomes → expect 0.025 ───────────────
# rows: pr1 price .9 (MERGED->1) err .01 ; pr2 price .2 (CLOSED->0) err .04 ;
#       pr3 price .5 (OPEN->skip).  Brier=(.01+.04)/2 = 0.025
cat > "$TMP/led2.jsonl" <<'J'
{"ts":"t","pr":1,"sha":"x","price":0.9,"state":"CLEAN"}
{"ts":"t","pr":2,"sha":"y","price":0.2,"state":"DIRTY"}
{"ts":"t","pr":3,"sha":"z","price":0.5,"state":"BLOCKED"}
J
cat > "$TMP/out.json" <<'J'
[{"number":1,"state":"MERGED"},{"number":2,"state":"CLOSED"},{"number":3,"state":"OPEN"}]
J
SET="$(PR_BOOK_LEDGER="$TMP/led2.jsonl" PR_BOOK_CALIB="$TMP/cal2.log" \
       PR_BOOK_OUTCOMES_FIXTURE="$TMP/out.json" bash "$SCRIPT" --settle 2>&1)"
echo "$SET" | grep -qE 'running Brier: 0\.025($| )' && pass "settle: Brier=0.025 correct" || { echo "$SET"; bad "settle: wrong Brier"; }
echo "$SET" | grep -qE 'resolved 2 of 3' && pass "settle: 2 of 3 resolved (open skipped)" || bad "settle: resolve count"
grep -q '"brier":0.025' "$TMP/cal2.log" 2>/dev/null && pass "settle: calibration row logged" || bad "settle: no calib row"

# ── settle on empty ledger must not crash ─────────────────────────────────────
: > "$TMP/empty.jsonl"
E="$(PR_BOOK_LEDGER="$TMP/empty.jsonl" PR_BOOK_CALIB="$TMP/cale.log" bash "$SCRIPT" --settle 2>&1)"
echo "$E" | grep -q "nothing to settle" && pass "settle: empty ledger handled" || bad "settle: empty ledger crash"

[[ $fail -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "FAILURES"; exit 1; }
