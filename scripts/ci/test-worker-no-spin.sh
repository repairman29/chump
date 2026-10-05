#!/usr/bin/env bash
# test-worker-no-spin.sh — RESILIENT-332
#
# Proves the worker picker (scripts/dispatch/_pick_and_claim_gap.py) can no
# longer SPIN on a preflight-failing or open-PR gap. 2026-08-15 incident:
# worker 2 emitted worker_stuck reason=preflight_fail 108x in 15min because the
# picker re-offered the SAME top gap every cycle after it failed pre-pick
# preflight, doing zero work.
#
# Structural fix, three layers (this file exercises A & B; C is proven by
# scripts/ci/test-organ-watchdog.sh):
#   A. Picker never re-offers a preflight-failing gap — worker.sh cools it down
#      per-worker on preflight fail; the picker's cooled_down_gaps() then
#      excludes it so the picker ADVANCES down the sorted list. When ALL
#      candidates are cooled the picker returns EMPTY (worker idles w/ backoff).
#   B. Gaps with an open PR / in-progress branch (IN_PROGRESS_GAPS, computed by
#      worker.sh from `git ls-remote`) are never offered.
#
# Acceptance criteria:
#   AC-1 (spin impossible): starting from a queue whose top gaps all fail
#        preflight, the picker ADVANCES to a workable gap and then converges to
#        EMPTY — it never returns the same cooled gap twice, and the total pick
#        count over the run is bounded (not 58/90s).
#   AC-2 (open-PR excluded): a gap in IN_PROGRESS_GAPS is never offered.
#   AC-3 (worker.sh wiring): worker.sh writes the per-worker cooldown on
#        preflight fail and computes+passes IN_PROGRESS_GAPS to the picker.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"
WORKER_SH="$REPO_ROOT/scripts/dispatch/worker.sh"

echo "=== RESILIENT-332 worker anti-SPIN tests ==="
[[ -f "$PICKER" ]] || { fail "worker picker not at $PICKER"; exit 1; }
ok "worker picker present"

TMP="$(mktemp -d -t worker-no-spin.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
LOCK_DIR="$TMP/locks"
COOLDOWN_DIR="$LOCK_DIR/cooldown"
mkdir -p "$COOLDOWN_DIR"

# Dry-run the picker (filter+rank only, no lease writes) so the test is a
# deterministic assertion of the exclusion filters (cooldown / in_progress).
# WORKER_ID is numeric so cooled_down_gaps() treats the cooldown file as a
# per-worker entry (mirrors worker.sh's numeric AGENT_ID).
run_picker() {
    local gaps_file="$1"; shift
    GAP_JSON_FILE="$gaps_file" \
    CHUMP_LOCK_DIR="$LOCK_DIR" \
    COOLDOWN_DIR="$COOLDOWN_DIR" \
    CHUMP_SESSION_ID="test-session-$$" \
    CHUMP_FLEET_DRY_RUN=1 \
    CHUMP_REBALANCE=0 \
    WORKER_INDEX=1 \
    WORKER_ID=1 \
      "$@" python3 "$PICKER"
}

# Write the per-worker cooldown EXACTLY as worker.sh's preflight-fail branch
# does (Layer A). Keeping this identical to worker.sh is what makes the
# simulation faithful; AC-3 below asserts worker.sh still writes this form.
cool_down_gap() {
    local gap="$1" worker="${2:-1}"
    local until=$(( $(date +%s) + 900 ))
    printf '{"gap_id":"%s","until":%d,"agent":"%s","ts":"%s","reason":"preflight_fail"}\n' \
        "$gap" "$until" "$worker" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$COOLDOWN_DIR/${worker}-${gap}.json"
}

# A 4-gap queue, all same priority/effort/age so the sort is by id (stable).
# TOP-A and TOP-B are the "stale-open" gaps that fail pre-pick preflight;
# WORKABLE-C is the first gap that actually passes; TAIL-D is below it.
cat > "$TMP/queue.json" <<'EOF'
[
  {"id":"AAA-1","domain":"INFRA","priority":"P1","effort":"s","status":"open",
   "created_at":1000,"depends_on":"[]",
   "acceptance_criteria":"[\"1. top stale-open gap A.\"]",
   "title":"stale-open A","outcome_id":null,"notes":"","description":""},
  {"id":"BBB-2","domain":"INFRA","priority":"P1","effort":"s","status":"open",
   "created_at":1000,"depends_on":"[]",
   "acceptance_criteria":"[\"1. top stale-open gap B.\"]",
   "title":"stale-open B","outcome_id":null,"notes":"","description":""},
  {"id":"CCC-3","domain":"INFRA","priority":"P1","effort":"s","status":"open",
   "created_at":1000,"depends_on":"[]",
   "acceptance_criteria":"[\"1. first workable gap C.\"]",
   "title":"workable C","outcome_id":null,"notes":"","description":""},
  {"id":"DDD-4","domain":"INFRA","priority":"P1","effort":"s","status":"open",
   "created_at":1000,"depends_on":"[]",
   "acceptance_criteria":"[\"1. tail workable gap D.\"]",
   "title":"workable D","outcome_id":null,"notes":"","description":""}
]
EOF

# ── AC-1: spin impossible — advance past preflight-failing gaps, then idle ──
# Simulate the worker loop: pick (dry-run) → if the pick is in the FAIL set,
# cool it down (Layer A) and loop; else it is the workable pick and we stop.
# A spinning picker would return AAA-1 (or ping-pong AAA-1/BBB-2) forever.
FAIL_SET=" AAA-1 BBB-2 "
picks=()
picked=""
max_iters=12   # generous bound; the fix converges in <= N(gaps)+1 = 5
i=0
while (( i < max_iters )); do
    i=$((i+1))
    p="$(FLEET_MODEL=opus run_picker "$TMP/queue.json")"
    picks+=("${p:-<empty>}")
    if [[ -z "$p" ]]; then
        break  # picker returned empty → worker would sleep idle-backoff
    fi
    if [[ "$FAIL_SET" == *" $p "* ]]; then
        cool_down_gap "$p" 1   # Layer A: worker.sh cools a preflight-failing gap
        continue
    fi
    picked="$p"
    break  # first gap that passes preflight — real work begins
done

echo "  pick sequence: ${picks[*]}"

# (a) advanced to the first workable gap (CCC-3), not stuck on AAA-1/BBB-2.
if [[ "$picked" == "CCC-3" ]]; then
    ok "AC-1a: picker ADVANCED past preflight-failing gaps to the workable gap (CCC-3)"
else
    fail "AC-1a: expected to reach CCC-3, got '$picked' (sequence: ${picks[*]})"
fi

# (b) never returned the same gap twice — a spin is literally re-offering the
#     same gap; assert every pick in the sequence is unique.
dups="$(printf '%s\n' "${picks[@]}" | grep -v '<empty>' | sort | uniq -d)"
if [[ -z "$dups" ]]; then
    ok "AC-1b: no gap was offered twice — the picker cannot re-offer a cooled gap"
else
    fail "AC-1b: a gap was re-offered (spin): [$dups]"
fi

# (c) bounded pick count: the run terminated well under the loop cap. A true
#     spin would hit max_iters every time (the incident was 58 picks/90s).
if (( ${#picks[@]} <= 5 )); then
    ok "AC-1c: pick count bounded (${#picks[@]} picks <= 5, not 58/90s)"
else
    fail "AC-1c: pick count not bounded (${#picks[@]} picks)"
fi

# ── AC-1d: ALL candidates fail preflight → picker returns EMPTY (worker idles)
rm -f "$COOLDOWN_DIR"/*.json 2>/dev/null || true
FAIL_SET=" AAA-1 BBB-2 CCC-3 DDD-4 "
picks2=()
i=0
last=""
while (( i < max_iters )); do
    i=$((i+1))
    p="$(FLEET_MODEL=opus run_picker "$TMP/queue.json")"
    picks2+=("${p:-<empty>}")
    if [[ -z "$p" ]]; then
        last="empty"; break
    fi
    cool_down_gap "$p" 1
done
if [[ "$last" == "empty" ]] && (( ${#picks2[@]} <= 5 )); then
    ok "AC-1d: all-fail queue converges to EMPTY pick in ${#picks2[@]} cycles (worker then idles w/ backoff)"
else
    fail "AC-1d: all-fail queue did not converge to empty (last=$last, ${#picks2[@]} picks: ${picks2[*]})"
fi

# ── AC-2: open-PR / in-progress-branch gap is never offered ─────────────────
rm -f "$COOLDOWN_DIR"/*.json 2>/dev/null || true
# AAA-1 is the top gap; mark it as having an open PR/branch (Layer B).
p="$(FLEET_MODEL=opus IN_PROGRESS_GAPS="AAA-1" run_picker "$TMP/queue.json")"
if [[ "$p" != "AAA-1" && -n "$p" ]]; then
    ok "AC-2: gap with an open PR/branch (AAA-1) not offered; picker returned '$p' instead"
else
    fail "AC-2: expected the picker to skip the in-progress gap AAA-1, got '$p'"
fi
# And a gap NOT in the in-progress set is still offered.
p="$(FLEET_MODEL=opus IN_PROGRESS_GAPS="BBB-2" run_picker "$TMP/queue.json")"
if [[ "$p" == "AAA-1" ]]; then
    ok "AC-2b: excluding BBB-2 still lets the real top gap AAA-1 through (no over-exclusion)"
else
    fail "AC-2b: expected AAA-1 when only BBB-2 is in-progress, got '$p'"
fi

# ── AC-3: worker.sh integration wiring is present ───────────────────────────
if [[ -f "$WORKER_SH" ]]; then
    # Layer A: cooldown write in the preflight-fail branch.
    if grep -q 'CHUMP_PREFLIGHT_FAIL_COOLDOWN_S' "$WORKER_SH" \
       && grep -qE '\$\{AGENT_ID\}-\$\{GAP_ID\}\.json' "$WORKER_SH"; then
        ok "AC-3a: worker.sh writes the per-worker cooldown on preflight fail (Layer A)"
    else
        fail "AC-3a: worker.sh preflight-fail cooldown write not found"
    fi
    # Layer B: computes IN_PROGRESS_GAPS and passes it to the picker.
    if grep -q 'in_progress_gaps=' "$WORKER_SH" \
       && grep -q 'IN_PROGRESS_GAPS="\$in_progress_gaps"' "$WORKER_SH"; then
        ok "AC-3b: worker.sh computes IN_PROGRESS_GAPS and passes it to the picker (Layer B)"
    else
        fail "AC-3b: worker.sh IN_PROGRESS_GAPS wiring not found"
    fi
    # Rate-limit floor so the interim before cooldowns accumulate can't hot-loop.
    if grep -q 'CHUMP_PREFLIGHT_FAIL_SLEEP_S' "$WORKER_SH"; then
        ok "AC-3c: worker.sh rate-limits the preflight-fail retry (bounds pick rate)"
    else
        fail "AC-3c: worker.sh preflight-fail rate-limit not found"
    fi
else
    fail "AC-3: worker.sh not found at $WORKER_SH"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ ${#FAILS[@]} -gt 0 ]]; then
    echo "Failed assertions:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
fi
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
