#!/usr/bin/env bash
# test-back-pressure-hysteresis.sh — RESILIENT-324
#
# Proves the back-pressure breaker can no longer permanently deadlock in the
# 4–5 hysteresis dead-zone, while still halting hard on a genuine 6+ jam.
#
# Exercises scripts/ops/back-pressure-controller.sh through its test hooks
# (CHUMP_BACKPRESSURE_PILE / _RUNNING + CHUMP_AUTON_FILE / _HALT_SINCE_FILE /
# _AMBIENT_FILE) with systemctl/gh/pkill stubbed on PATH, so no root, no live
# GitHub, and no live systemd are needed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CTRL="$REPO_ROOT/scripts/ops/back-pressure-controller.sh"
[[ -f "$CTRL" ]] || { echo "FAIL: $CTRL not found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── stub bin: systemctl / gh / pkill are no-ops that always succeed ───────────
STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
# only `gh api user` should ever reach here (pile is injected via env)
[[ "$1" == "api" ]] && { echo "repairman29"; exit 0; }
exit 0
EOF
cat > "$STUB/pkill" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"

AUTON="$TMP/AUTONOMY_LEVEL"
HALTSINCE="$TMP/halt_since"
AMBIENT="$TMP/ambient.jsonl"

run_ctrl() { # pile running  (env AUTON preset + HALTSINCE preset done by caller)
    CHUMP_BACKPRESSURE_PILE="$1" \
    CHUMP_BACKPRESSURE_RUNNING="$2" \
    CHUMP_AUTON_FILE="$AUTON" \
    CHUMP_HALT_SINCE_FILE="$HALTSINCE" \
    CHUMP_AMBIENT_FILE="$AMBIENT" \
    bash "$CTRL" 2>&1
}

pass=0; fail=0
ok()   { echo "  ok: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }

# ── Scenario A: genuine 6+ jam still HALTS ────────────────────────────────────
echo "== A: pile=6, workers running → must HALT (autonomy→0) =="
echo 5 > "$AUTON"; rm -f "$HALTSINCE"
out="$(run_ctrl 6 1)"
echo "$out" | grep -q "HALTING production" && ok "halted on 6+ jam" || bad "did not halt on 6+ jam"
[[ "$(cat "$AUTON")" == "0" ]] && ok "autonomy written to 0" || bad "autonomy not 0 (got '$(cat "$AUTON")')"
[[ -s "$HALTSINCE" ]] && ok "stuck-clock started" || bad "stuck-clock file not created"

# ── Scenario B: dead-zone, stuck-clock NOT yet elapsed → HOLD (no resume) ─────
echo "== B: pile=4, workers=0, autonomy=0, freshly halted → HOLD, no resume =="
echo 0 > "$AUTON"; date +%s > "$HALTSINCE"   # halted just now
out="$(run_ctrl 4 0)"
echo "$out" | grep -q "before escape-resume" && ok "held in dead-zone (clock ticking)" || bad "did not hold: $out"
[[ "$(cat "$AUTON")" == "0" ]] && ok "autonomy stayed 0 (no premature resume)" || bad "autonomy changed prematurely"

# ── Scenario C: dead-zone, stuck-clock ELAPSED → ESCAPE RESUME ────────────────
echo "== C: pile=5, workers=0, autonomy=0, halted 2000s ago → ESCAPE RESUME =="
echo 0 > "$AUTON"; echo "$(( $(date +%s) - 2000 ))" > "$HALTSINCE"
out="$(run_ctrl 5 0)"
echo "$out" | grep -qi "dead-zone escape" && ok "escape-resume fired" || bad "escape did not fire: $out"
[[ "$(cat "$AUTON")" == "5" ]] && ok "autonomy restored to 5" || bad "autonomy not restored (got '$(cat "$AUTON")')"
[[ ! -f "$HALTSINCE" ]] && ok "stuck-clock cleared on resume" || bad "stuck-clock not cleared"
grep -q "backpressure_stuck_escape" "$AMBIENT" && ok "escape event emitted" || bad "no escape event in ambient"

# ── Scenario D: fast resume when genuinely drained (pile<=RESUME_AT) ──────────
echo "== D: pile=2, workers=0, autonomy=0 → fast RESUME (no wait) =="
echo 0 > "$AUTON"; date +%s > "$HALTSINCE"   # even freshly halted, drained → resume now
out="$(run_ctrl 2 0)"
echo "$out" | grep -q "queue drained" && ok "fast resume on drain" || bad "no fast resume: $out"
[[ "$(cat "$AUTON")" == "5" ]] && ok "autonomy restored to 5" || bad "autonomy not restored"

# ── Scenario E: healthy running state → no change ─────────────────────────────
echo "== E: pile=4, workers=2, autonomy=5 → no change (not halted) =="
echo 5 > "$AUTON"; rm -f "$HALTSINCE"
out="$(run_ctrl 4 2)"
echo "$out" | grep -q "no change" && ok "no change while healthy" || bad "unexpected action: $out"
[[ "$(cat "$AUTON")" == "5" ]] && ok "autonomy untouched" || bad "autonomy changed while healthy"

# ── Scenario F: autonomy write failure is tolerated (chattr +i sim) ───────────
echo "== F: read-only autonomy file → resume tolerates write failure, no crash =="
echo 0 > "$AUTON"; echo "$(( $(date +%s) - 2000 ))" > "$HALTSINCE"; chmod 0444 "$AUTON"
set +e
out="$(run_ctrl 5 0)"; rc=$?
set -e 2>/dev/null || true
chmod 0644 "$AUTON"
[[ "$rc" -eq 0 ]] && ok "controller exited 0 despite locked autonomy file" || bad "controller crashed (rc=$rc)"
echo "$out" | grep -qi "could not write autonomy" && ok "logged the write failure gracefully" || bad "no graceful-write-failure log"

# ── RESILIENT-308: systemic-red awareness ─────────────────────────────────────
# The classifier is exercised through CHUMP_BACKPRESSURE_PRFACTS (+ _MAINFACTS),
# which feed real PR facts to classify_pile() instead of the live gh probe. These
# prove the breaker halts on a GENUINE jam but NOT on flaky/shared (systemic) red.
run_ctrl_facts() { # prfacts_json mainfacts_json running  (AUTON/HALTSINCE preset by caller)
    local pf="$TMP/prfacts.json" mf="$TMP/mainfacts.json"
    printf '%s' "$1" > "$pf"; printf '%s' "$2" > "$mf"
    CHUMP_BACKPRESSURE_PRFACTS="$pf" \
    CHUMP_BACKPRESSURE_MAINFACTS="$mf" \
    CHUMP_BACKPRESSURE_RUNNING="$3" \
    CHUMP_BACKPRESSURE_RERUN_DISABLED=1 \
    CHUMP_BACKPRESSURE_HALT_AT="${HALT_AT_OVERRIDE:-6}" \
    CHUMP_AUTON_FILE="$AUTON" \
    CHUMP_HALT_SINCE_FILE="$HALTSINCE" \
    CHUMP_AMBIENT_FILE="$AMBIENT" \
    bash "$CTRL" 2>&1
}

# ── Scenario G: 6 PRs all BLOCKED failing the SAME check (shared/flaky) → NO HALT
echo "== G: 6 PRs all BLOCKED failing the SAME 'audit' check → systemic-red, must NOT halt =="
echo 5 > "$AUTON"; rm -f "$HALTSINCE"; : > "$AMBIENT"
PF='[{"number":1,"mergeStateStatus":"BLOCKED","checks":[{"name":"audit","conclusion":"CANCELLED"}]},
    {"number":2,"mergeStateStatus":"BLOCKED","checks":[{"name":"audit","conclusion":"CANCELLED"}]},
    {"number":3,"mergeStateStatus":"BLOCKED","checks":[{"name":"audit","conclusion":"CANCELLED"}]},
    {"number":4,"mergeStateStatus":"BLOCKED","checks":[{"name":"audit","conclusion":"CANCELLED"}]},
    {"number":5,"mergeStateStatus":"BLOCKED","checks":[{"name":"audit","conclusion":"CANCELLED"}]},
    {"number":6,"mergeStateStatus":"BLOCKED","checks":[{"name":"audit","conclusion":"CANCELLED"}]}]'
out="$(run_ctrl_facts "$PF" '[]' 1)"
echo "$out" | grep -q "HALTING production" && bad "halted on a systemic-red cascade (should not)" || ok "did NOT halt on shared/flaky red"
echo "$out" | grep -q "genuine-jam=0 systemic-red=6" && ok "classified 0 genuine / 6 systemic" || bad "misclassified: $out"
echo "$out" | grep -q "SYSTEMIC-RED" && ok "loud systemic-red signal emitted" || bad "no systemic-red signal"
grep -q "systemic_red" "$AMBIENT" && ok "systemic_red ambient event written" || bad "no systemic_red in ambient"
[[ "$(cat "$AUTON")" == "5" ]] && ok "autonomy stayed 5 (fleet not halted)" || bad "autonomy changed (halted victims)"

# ── Scenario H: same check ALSO failing on origin/main HEAD → systemic → NO HALT
echo "== H: 6 PRs failing 'test', 'test' also RED on main → systemic (main-gate), must NOT halt =="
echo 5 > "$AUTON"; rm -f "$HALTSINCE"; : > "$AMBIENT"
PF='[{"number":11,"mergeStateStatus":"BLOCKED","checks":[{"name":"test","conclusion":"FAILURE"}]},
    {"number":12,"mergeStateStatus":"BLOCKED","checks":[{"name":"test","conclusion":"FAILURE"}]},
    {"number":13,"mergeStateStatus":"BLOCKED","checks":[{"name":"test","conclusion":"FAILURE"}]},
    {"number":14,"mergeStateStatus":"BLOCKED","checks":[{"name":"test","conclusion":"FAILURE"}]},
    {"number":15,"mergeStateStatus":"BLOCKED","checks":[{"name":"test","conclusion":"FAILURE"}]},
    {"number":16,"mergeStateStatus":"BLOCKED","checks":[{"name":"test","conclusion":"FAILURE"}]}]'
out="$(run_ctrl_facts "$PF" '[{"name":"test","conclusion":"FAILURE"}]' 1)"
echo "$out" | grep -q "HALTING production" && bad "halted while main's own gate is red (should not)" || ok "did NOT halt when the failure is main-gate-wide"
echo "$out" | grep -q "systemic-red=6" && ok "all 6 spared as main-gate victims" || bad "misclassified: $out"

# ── Scenario I: 6 real merge CONFLICTS (DIRTY) → genuine jam, STILL HALTS ──────
echo "== I: 6 PRs DIRTY (real merge conflicts) → genuine jam, must HALT =="
echo 5 > "$AUTON"; rm -f "$HALTSINCE"; : > "$AMBIENT"
PF='[{"number":21,"mergeStateStatus":"DIRTY","checks":[]},
    {"number":22,"mergeStateStatus":"DIRTY","checks":[]},
    {"number":23,"mergeStateStatus":"DIRTY","checks":[]},
    {"number":24,"mergeStateStatus":"CONFLICTING","checks":[]},
    {"number":25,"mergeStateStatus":"CONFLICTING","checks":[]},
    {"number":26,"mergeStateStatus":"CONFLICTING","checks":[]}]'
out="$(run_ctrl_facts "$PF" '[]' 1)"
echo "$out" | grep -q "HALTING production" && ok "STILL halts on a genuine conflict jam" || bad "failed to halt on real conflicts: $out"
echo "$out" | grep -q "genuine-jam=6 systemic-red=0" && ok "classified 6 genuine / 0 systemic" || bad "misclassified: $out"
[[ "$(cat "$AUTON")" == "0" ]] && ok "autonomy driven to 0 (halted)" || bad "did not halt real jam"

# ── Scenario J: mixed — 2 real PR-specific failures + 3 flaky victims ─────────
# Proves the two behaviors coexist in one pass: the real per-PR failures HALT
# (at HALT_AT=2) while the shared/flaky victims are spared as systemic-red.
echo "== J: HALT_AT=2, 2 unique real failures + 3 shared-flaky → HALT on the 2, spare the 3 =="
echo 5 > "$AUTON"; rm -f "$HALTSINCE"; : > "$AMBIENT"
PF='[{"number":31,"mergeStateStatus":"BLOCKED","checks":[{"name":"unique-a","conclusion":"FAILURE"}]},
    {"number":32,"mergeStateStatus":"BLOCKED","checks":[{"name":"unique-b","conclusion":"FAILURE"}]},
    {"number":33,"mergeStateStatus":"BLOCKED","checks":[{"name":"shared-flaky","conclusion":"CANCELLED"}]},
    {"number":34,"mergeStateStatus":"BLOCKED","checks":[{"name":"shared-flaky","conclusion":"CANCELLED"}]},
    {"number":35,"mergeStateStatus":"BLOCKED","checks":[{"name":"shared-flaky","conclusion":"CANCELLED"}]}]'
out="$(HALT_AT_OVERRIDE=2 run_ctrl_facts "$PF" '[]' 1)"
echo "$out" | grep -q "genuine-jam=2 systemic-red=3" && ok "classified 2 genuine (unique) / 3 systemic (shared)" || bad "misclassified: $out"
echo "$out" | grep -q "HALTING production" && ok "halts on the 2 real per-PR failures" || bad "did not halt on real failures: $out"
echo "$out" | grep -q "SYSTEMIC-RED: 3" && ok "the 3 shared-flaky spared + signalled simultaneously" || bad "flaky victims not spared"

echo ""
echo "=== back-pressure hysteresis: $pass passed, $fail failed ==="
[[ "$fail" -eq 0 ]]
