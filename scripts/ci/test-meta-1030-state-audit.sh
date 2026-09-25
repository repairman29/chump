#!/usr/bin/env bash
# test-meta-1030-state-audit.sh — META-1030 acceptance test for the deterministic
# state-audit / reconciliation organ (scripts/coord/state-audit-reconcile.sh).
#
# Proves the load-bearing behavior with FIXTURES (no live fleet state touched):
#   A. SEEDED LIE (check 1: cycle_kind_vs_pr) → organ DETECTS it AND pages via a
#      stubbed operator-recall (emits condition=STATE_DIVERGENCE to a fixture
#      ambient log). Proves the page fires.
#   B. CLEAN state (same shape, gap NOT shipped) → organ stays quiet: no
#      divergence, no operator-recall page. Proves it does NOT false-page.
#   C. A check that cannot get ground truth reports UNKNOWN, never a false AGREE.
#
# Deterministic, offline, no inference. Exits non-zero on any assertion failure.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
ORGAN="$REPO_ROOT/scripts/coord/state-audit-reconcile.sh"

PASS=0; FAIL=0
ok()   { echo "  ok: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Stub operator-recall so a "page" is observable without touching the real pager.
STUB_RECALL="$WORK/operator-recall-stub.sh"
cat > "$STUB_RECALL" <<'STUB'
#!/usr/bin/env bash
# records the page to $STATE_AUDIT_TEST_PAGELOG
cond=""; reason=""
while [[ $# -gt 0 ]]; do case "$1" in
  --condition) cond="$2"; shift 2;; --reason) reason="$2"; shift 2;; *) shift;; esac; done
printf 'PAGE condition=%s reason=%s\n' "$cond" "$reason" >> "$STATE_AUDIT_TEST_PAGELOG"
echo "[stub-recall] PAGE condition=$cond"
STUB
chmod +x "$STUB_RECALL"

run_organ() { # $1=ambient $2=shipped_file $3=pagelog  -> runs `audit`, prints report
    STATE_AUDIT_TEST_PAGELOG="$3" \
    CHUMP_AMBIENT_LOG="$1" \
    CHUMP_STATE_AUDIT_SHIPPED_FILE="$2" \
    CHUMP_STATE_AUDIT_RECALL="$STUB_RECALL" \
    CHUMP_STATE_AUDIT_STATE_DB="$WORK/nonexistent.db" \
    CHUMP_STATE_AUDIT_WORKER_UNIT="__none__" \
    CHUMP_STATE_AUDIT_SYSTEMCTL="$WORK/systemctl-none.sh" \
    CHUMP_STATE_AUDIT_AUTH_STATUS="$WORK/nonexistent-auth.sh" \
    bash "$ORGAN" audit 2>&1
}

# a systemctl stub that reports nothing active (forces checks 2/3 to UNKNOWN, not false)
cat > "$WORK/systemctl-none.sh" <<'SC'
#!/usr/bin/env bash
case "$*" in
  *"is-active"*) exit 3;;
  *"show"*) echo ""; exit 0;;
  *"list-units"*) echo ""; exit 0;;
esac
exit 0
SC
chmod +x "$WORK/systemctl-none.sh"

[[ -x "$ORGAN" ]] || { echo "FAIL: organ not executable at $ORGAN"; exit 1; }

# ── A. SEEDED LIE: worker_exit FAILED for a gap that IS shipped ───────────────
echo "== A. seeded lie (cycle_kind_vs_pr) should DIVERGE + PAGE =="
AMB_A="$WORK/ambient_lie.jsonl"
SHIP_A="$WORK/shipped_lie.txt"
PAGE_A="$WORK/page_lie.log"; : > "$PAGE_A"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"worker_exit","gap_id":"SEED-001","rc":1,"exit_class":"FAILED"}\n' "$NOW_ISO" > "$AMB_A"
echo "SEED-001" > "$SHIP_A"
OUT_A="$(run_organ "$AMB_A" "$SHIP_A" "$PAGE_A")"
echo "$OUT_A" | sed 's/^/    /'
echo "$OUT_A" | grep -qE 'cycle_kind_vs_pr .*DIVERGE'   && ok "seeded lie flagged DIVERGE" || bad "seeded lie NOT flagged"
grep -qE 'PAGE condition=STATE_DIVERGENCE' "$PAGE_A"     && ok "operator-recall PAGED (STATE_DIVERGENCE)" || bad "no page emitted"
grep -qE 'SEED-001' "$PAGE_A"                            && ok "page names the offending gap" || bad "page missing gap id"
grep -qE '"kind":"state_audit_divergence"' "$AMB_A"      && ok "state_audit_divergence emitted to ambient" || bad "no divergence ambient event"

# ── B. CLEAN: same failure label but gap NOT shipped → quiet ──────────────────
echo "== B. clean state should stay QUIET (no page) =="
AMB_B="$WORK/ambient_clean.jsonl"
SHIP_B="$WORK/shipped_clean.txt"   # empty: SEED-001 not shipped
PAGE_B="$WORK/page_clean.log"; : > "$PAGE_B"; : > "$SHIP_B"
printf '{"ts":"%s","kind":"worker_exit","gap_id":"SEED-001","rc":1,"exit_class":"FAILED"}\n' "$NOW_ISO" > "$AMB_B"
OUT_B="$(run_organ "$AMB_B" "$SHIP_B" "$PAGE_B")"
echo "$OUT_B" | sed 's/^/    /'
echo "$OUT_B" | grep -qE 'cycle_kind_vs_pr .*AGREE'      && ok "clean cycle_kind_vs_pr AGREE (failure not shipped)" || bad "clean state not AGREE"
[[ ! -s "$PAGE_B" ]]                                     && ok "no page on clean state" || bad "FALSE PAGE on clean state: $(cat "$PAGE_B")"

# ── C. UNKNOWN, never false AGREE, when ground truth is missing ───────────────
echo "== C. missing ground truth → UNKNOWN (not AGREE) =="
echo "$OUT_B" | grep -qE 'done_vs_running .*(UNKNOWN|DIVERGE)' && ok "done_vs_running is UNKNOWN/DIVERGE without a worker unit (not false AGREE)" || bad "done_vs_running wrongly AGREE"
echo "$OUT_B" | grep -qE 'picker_vs_preflight .*UNKNOWN'  && ok "picker_vs_preflight honestly UNKNOWN (follow-up)" || bad "picker_vs_preflight not UNKNOWN"
echo "$OUT_B" | grep -qE 'node_last_seen .*UNKNOWN'       && ok "node_last_seen UNKNOWN without expected-node config (no false page)" || bad "node_last_seen not UNKNOWN"

echo "-------------------------------------------"
echo "META-1030 state-audit: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
