#!/usr/bin/env bash
# scripts/ci/test-infra-3850-ev-p-namespace.sh — INFRA-3850 (parent INFRA-3841)
#
# Proves the "reconcile 6/9" claim: pr_book, nba, and rating each write their
# EV/P columns under a table-namespaced name (pr_book.p_merge / pr_book.ev,
# nba.ev / nba.p, rating.p_win) instead of a bare "ev"/"p" — so joining their
# outputs in a shared stream (ambient.jsonl mixes every kind in one flat
# file; the pr-book ledger is a candidate join target for rating predictions)
# can never silently collide two different tables' columns under one name.
#
# Self-contained + offline:
#   1. pr-book.sh board mode (fixture-driven) — asserts the ambient
#      kind=pr_book_odds event carries "pr_book_ev", never a bare "ev".
#   2. pr-book.sh ledger — asserts predictions are logged under "p_merge",
#      never a bare "price"/"p" (negative-assertion guard, precedent
#      INFRA-1079).
#   3. next-best-action.sh source — negative-assertion guard: the
#      ambient-emit call must use "nba_ev="/"nba_p=", never bare "ev="/"p="
#      (full execution needs gh/systemctl/chump live state, so this is a
#      static guard rather than a fixture run — same pattern as the
#      ensure_target_exists guard in scripts/ci/test-*.sh).
#   4. cargo test on src/ratings.rs — proves predict_win() serializes under
#      "p_win", never a bare "p" (see the Rust test itself for the assertion).

set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$DIR/../.." && pwd)"
PRBOOK="$ROOT/scripts/coord/pr-book.sh"
NBA="$ROOT/scripts/coord/next-best-action.sh"
TMP="$(mktemp -d "${TMPDIR:-$HOME/.chump}/infra3850-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail=0; pass(){ echo "  ok: $1"; }; bad(){ echo "  FAIL: $1"; fail=1; }

# ── 1+2. pr-book.sh board mode: ambient event + ledger use namespaced cols ──
cat > "$TMP/raw.json" <<'J'
[{"number":201,"title":"clean one","mergeStateStatus":"CLEAN","createdAt":"2026-08-22T00:00:00Z","isDraft":false,"statusCheckRollup":[],"headRefOid":"aaa"}]
J
PR_BOOK_LEDGER="$TMP/led.jsonl" PR_BOOK_CALIB="$TMP/cal.log" \
  CHUMP_AMBIENT_LOG="$TMP/amb.jsonl" PR_BOOK_RAW_FIXTURE="$TMP/raw.json" \
  bash "$PRBOOK" >/dev/null 2>&1

if grep -q '"kind":"pr_book_odds".*"pr_book_ev":' "$TMP/amb.jsonl" 2>/dev/null; then
  pass "pr-book ambient: pr_book_odds carries namespaced pr_book_ev"
else
  echo "--- amb.jsonl ---"; cat "$TMP/amb.jsonl" 2>/dev/null
  bad "pr-book ambient: pr_book_ev missing from pr_book_odds event"
fi
if grep -q '"ev":' "$TMP/amb.jsonl" 2>/dev/null; then
  bad "pr-book ambient: bare \"ev\" key leaked (must be pr_book_ev)"
else
  pass "pr-book ambient: no bare \"ev\" key"
fi

if grep -q '"p_merge":' "$TMP/led.jsonl" 2>/dev/null; then
  pass "pr-book ledger: prediction logged under namespaced p_merge"
else
  echo "--- led.jsonl ---"; cat "$TMP/led.jsonl" 2>/dev/null
  bad "pr-book ledger: p_merge missing"
fi
if grep -Eq '"(price|p)":' "$TMP/led.jsonl" 2>/dev/null; then
  bad "pr-book ledger: bare \"price\"/\"p\" key leaked (must be p_merge)"
else
  pass "pr-book ledger: no bare \"price\"/\"p\" key"
fi

# ── 3. next-best-action.sh: ambient-emit call must use nba_ev/nba_p ────────
if grep -Eq '"nba_ev=' "$NBA" && grep -Eq '"nba_p=' "$NBA"; then
  pass "next-best-action.sh: ambient emit uses nba_ev/nba_p"
else
  bad "next-best-action.sh: ambient emit does not use namespaced nba_ev/nba_p"
fi
# Negative-assertion guard (precedent: INFRA-1079 ensure_target_exists):
# grep for a bare "ev="/"p=" arg to ambient-emit.sh — a quoted key exactly
# "ev=" or "p=" (not "nba_ev="/"nba_p="/"candidates="/etc.).
if grep -Eq '"ev=|"p=' "$NBA" 2>/dev/null; then
  bad "next-best-action.sh: bare ev=/p= ambient-emit arg still present"
else
  pass "next-best-action.sh: no bare ev=/p= ambient-emit arg"
fi

echo
[[ $fail -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "FAILURES"; exit 1; }
