#!/usr/bin/env bash
# test-recurring-gap-pattern-detector.sh — INFRA-249 unit tests.
#
# Verifies the recurring-gap-pattern-detector script:
#   (1) Detects a cluster when ≥THRESHOLD gaps share a non-stopword keyword
#       in titles within DAYS window
#   (2) Skips gaps outside the DAYS window
#   (3) Skips stopword keywords (chump, only, infra, etc.)
#   (4) Threshold respected — N=2 with threshold=3 produces no cluster
#   (5) Emits ambient.jsonl ALERT line per cluster with correct JSON shape
#   (6) --quiet suppresses stdout but still emits ambient lines
#   (7) Skips gaps with no opened_date (legacy)
#
# Run: ./scripts/ci/test-recurring-gap-pattern-detector.sh

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-249 recurring-gap-pattern-detector unit tests ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DETECTOR="$REPO_ROOT/scripts/coord/recurring-gap-pattern-detector.sh"

if [ ! -x "$DETECTOR" ]; then
    chmod +x "$DETECTOR" 2>/dev/null || true
fi
if [ ! -x "$DETECTOR" ]; then
    echo "FATAL: detector script not executable: $DETECTOR"
    exit 2
fi

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

FAKE_REPO="$TMPDIR_BASE/repo"
mkdir -p "$FAKE_REPO/docs/gaps" "$FAKE_REPO/.chump-locks"
git -C "$FAKE_REPO" init -q -b main
git -C "$FAKE_REPO" config user.email t@t
git -C "$FAKE_REPO" config user.name T

TODAY=$(date -u +%Y-%m-%d)
if [ "$(uname -s)" = "Darwin" ]; then
    YESTERDAY=$(date -u -v-1d +%Y-%m-%d)
    LAST_WEEK=$(date -u -v-5d +%Y-%m-%d)
    OLD=$(date -u -v-30d +%Y-%m-%d)
else
    YESTERDAY=$(date -u -d "1 day ago" +%Y-%m-%d)
    LAST_WEEK=$(date -u -d "5 days ago" +%Y-%m-%d)
    OLD=$(date -u -d "30 days ago" +%Y-%m-%d)
fi

seed_gap() {
    local id="$1" opened="$2" title="$3"
    cat > "$FAKE_REPO/docs/gaps/$id.yaml" <<YAML
- id: $id
  domain: infra
  title: "$title"
  status: open
  opened_date: '$opened'
YAML
}

reset_repo() {
    rm -rf "$FAKE_REPO/docs/gaps"
    mkdir -p "$FAKE_REPO/docs/gaps"
    rm -f "$FAKE_REPO/.chump-locks/ambient.jsonl"
}

run_detector() {
    local ambient_file="$1"
    shift
    ( cd "$FAKE_REPO" && CHUMP_AMBIENT_LOG="$ambient_file" "$DETECTOR" "$@" 2>&1 )
}

# ── Test 1: cluster detected when ≥3 gaps share a keyword ────────────────────
echo "--- Test 1: cluster detected when 3 gaps share keyword 'restoration' ---"
reset_repo
seed_gap "TEST-001" "$TODAY"     "restoration of broken thing"
seed_gap "TEST-002" "$YESTERDAY" "restoration policy update"
seed_gap "TEST-003" "$LAST_WEEK" "restoration helper script"
amb="$FAKE_REPO/.chump-locks/ambient.jsonl"
out=$(run_detector "$amb" --days 7 --threshold 3)
if echo "$out" | grep -q "CLUSTER.*restoration.*3 gaps"; then
    ok "Test 1: 'restoration' cluster detected (n=3, threshold=3)"
else
    fail "Test 1: cluster not detected; output: $out"
fi

# ── Test 2: gaps outside DAYS window are skipped ─────────────────────────────
echo "--- Test 2: 30-day-old gap excluded from 7-day window ---"
reset_repo
seed_gap "TEST-001" "$TODAY"     "deletion routine"
seed_gap "TEST-002" "$YESTERDAY" "deletion safety"
seed_gap "TEST-OLD" "$OLD"       "deletion ancient"
out=$(run_detector "$FAKE_REPO/.chump-locks/ambient.jsonl" --days 7 --threshold 3)
if echo "$out" | grep -q "CLUSTER.*deletion"; then
    fail "Test 2: 30-day-old gap should have been excluded; got false-positive cluster"
else
    ok "Test 2: old gap excluded — no cluster reported (only 2 in-window)"
fi

# ── Test 3: stopword keywords skipped ────────────────────────────────────────
echo "--- Test 3: stopword 'chump' does not form a cluster ---"
reset_repo
seed_gap "TEST-001" "$TODAY"     "chump dispatch reliability"
seed_gap "TEST-002" "$YESTERDAY" "chump rebuild guidance"
seed_gap "TEST-003" "$LAST_WEEK" "chump install path"
out=$(run_detector "$FAKE_REPO/.chump-locks/ambient.jsonl" --days 7 --threshold 3)
if echo "$out" | grep -q "CLUSTER.*chump"; then
    fail "Test 3: stopword 'chump' should not form a cluster"
else
    ok "Test 3: stopword 'chump' correctly excluded from clustering"
fi

# ── Test 4: threshold respected — N=2 with threshold=3 → no cluster ──────────
echo "--- Test 4: threshold=3 requires at least 3 gaps ---"
reset_repo
seed_gap "TEST-001" "$TODAY"     "rebalance heuristic"
seed_gap "TEST-002" "$YESTERDAY" "rebalance metric"
out=$(run_detector "$FAKE_REPO/.chump-locks/ambient.jsonl" --days 7 --threshold 3)
if echo "$out" | grep -q "CLUSTER.*rebalance"; then
    fail "Test 4: 2 gaps with shared keyword should NOT cluster at threshold=3"
else
    ok "Test 4: threshold=3 correctly rejects N=2 cluster"
fi
out=$(run_detector "$FAKE_REPO/.chump-locks/ambient.jsonl" --days 7 --threshold 2)
if echo "$out" | grep -q "CLUSTER.*rebalance.*2 gaps"; then
    ok "Test 4 lower-threshold: same data clusters at threshold=2"
else
    fail "Test 4 lower-threshold: should cluster at threshold=2; output: $out"
fi

# ── Test 5: ambient.jsonl ALERT line shape ───────────────────────────────────
echo "--- Test 5: ambient ALERT line emitted with correct JSON fields ---"
reset_repo
seed_gap "TEST-001" "$TODAY"     "phantom interaction with provider"
seed_gap "TEST-002" "$YESTERDAY" "phantom rendering issue"
seed_gap "TEST-003" "$LAST_WEEK" "phantom callback trace"
amb="$FAKE_REPO/.chump-locks/ambient.jsonl"
run_detector "$amb" --days 7 --threshold 3 >/dev/null
if [ ! -f "$amb" ]; then
    fail "Test 5: ambient.jsonl was not created"
else
    line=$(head -1 "$amb")
    # Verify all required fields present
    missing=""
    for field in '"event":"ALERT"' '"kind":"recurring_gap_pattern"' '"keyword":"phantom"' '"gap_count":3' '"window_days":7' '"gap_ids"' '"ts"' '"session"'; do
        if ! echo "$line" | grep -q "$field"; then
            missing="$missing $field"
        fi
    done
    if [ -z "$missing" ]; then
        ok "Test 5: ambient ALERT line has all required JSON fields"
    else
        fail "Test 5: ambient ALERT line missing fields:$missing"
        echo "      line: $line"
    fi
fi

# ── Test 6: --quiet suppresses stdout but emits ambient ──────────────────────
echo "--- Test 6: --quiet suppresses stdout, ambient still written ---"
reset_repo
seed_gap "TEST-001" "$TODAY"     "leakage handling routine"
seed_gap "TEST-002" "$YESTERDAY" "leakage prevention"
seed_gap "TEST-003" "$LAST_WEEK" "leakage audit"
amb="$FAKE_REPO/.chump-locks/ambient.jsonl"
out=$(run_detector "$amb" --days 7 --threshold 3 --quiet)
if [ -z "$out" ]; then
    if [ -f "$amb" ] && grep -q "leakage" "$amb"; then
        ok "Test 6: --quiet suppressed stdout AND ambient still written"
    else
        fail "Test 6: --quiet suppressed stdout but ambient also missing"
    fi
else
    fail "Test 6: --quiet should produce no stdout, got: $out"
fi

# ── Test 7: gap with no opened_date is skipped ───────────────────────────────
echo "--- Test 7: gap with no opened_date is silently skipped ---"
reset_repo
seed_gap "TEST-001" "$TODAY"     "boundary check work"
seed_gap "TEST-002" "$YESTERDAY" "boundary detection"
# Hand-write one without opened_date — should be skipped
cat > "$FAKE_REPO/docs/gaps/TEST-LEGACY.yaml" <<YAML
- id: TEST-LEGACY
  domain: infra
  title: "boundary legacy gap from before opened_date"
  status: open
YAML
out=$(run_detector "$FAKE_REPO/.chump-locks/ambient.jsonl" --days 7 --threshold 3)
if echo "$out" | grep -q "CLUSTER.*boundary"; then
    fail "Test 7: legacy gap counted; should have been skipped (no opened_date)"
else
    ok "Test 7: legacy gap (no opened_date) correctly skipped"
fi
out2=$(run_detector "$FAKE_REPO/.chump-locks/ambient.jsonl" --days 7 --threshold 2)
if echo "$out2" | grep -q "CLUSTER.*boundary.*2 gaps"; then
    ok "Test 7 confirm: only the 2 dated gaps cluster (legacy excluded from count)"
else
    fail "Test 7 confirm: expected cluster of 2 (excluding legacy); output: $out2"
fi

# ── Test 8: RCA reflex — cluster fires a META RCA gap + hold record ──────────
echo "--- Test 8: cluster detection files RCA gap + writes hold record (RESILIENT-365) ---"
reset_repo
seed_gap "TEST-001" "$TODAY"     "reconcile drift in the widget layer"
seed_gap "TEST-002" "$YESTERDAY" "reconcile drift after restart"
seed_gap "TEST-003" "$LAST_WEEK" "reconcile drift on cold boot"

FAKE_BIN="$TMPDIR_BASE/fakebin"
mkdir -p "$FAKE_BIN"
RESERVE_LOG="$TMPDIR_BASE/reserve.log"
SET_LOG="$TMPDIR_BASE/set.log"
: > "$RESERVE_LOG"
: > "$SET_LOG"
cat > "$FAKE_BIN/chump" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "gap reserve" ]; then
    echo "\$*" >> "$RESERVE_LOG"
    echo "META-9001"
    exit 0
fi
if [ "\$1 \$2" = "gap set" ]; then
    echo "\$*" >> "$SET_LOG"
    exit 0
fi
exit 1
EOF
chmod +x "$FAKE_BIN/chump"

amb="$FAKE_REPO/.chump-locks/ambient.jsonl"
state="$FAKE_REPO/.chump-locks/pattern-detector-state.json"
hold="$FAKE_REPO/.chump-locks/pattern-detector-hold.json"
out=$(cd "$FAKE_REPO" && PATH="$FAKE_BIN:$PATH" CHUMP_AMBIENT_LOG="$amb" \
    CHUMP_PATTERN_DETECTOR_STATE="$state" CHUMP_PATTERN_DETECTOR_HOLD="$hold" \
    CHUMP_RCA_REFLEX_ENABLED=1 CHUMP_RCA_REFLEX_LLM_DISABLED=1 \
    "$DETECTOR" --days 7 --threshold 3 2>&1)

if grep -q "gap reserve --domain META" "$RESERVE_LOG"; then
    ok "Test 8a: RCA reflex called 'chump gap reserve --domain META'"
else
    fail "Test 8a: expected a META gap reserve call; log: $(cat "$RESERVE_LOG" 2>/dev/null)"
fi

if grep -q -- "--evidence" "$RESERVE_LOG" && grep -q "THEORY:" "$RESERVE_LOG" && grep -q "ALT:" "$RESERVE_LOG"; then
    ok "Test 8a2: reserve call carries a COMMAND/OUTPUT/THEORY/ALT evidence blob"
else
    fail "Test 8a2: expected --evidence with THEORY/ALT; log: $(cat "$RESERVE_LOG" 2>/dev/null)"
fi

if [ -f "$state" ] && grep -q "META-9001" "$state" && grep -q "reconcile" "$state"; then
    ok "Test 8b: state file records keyword → RCA gap id"
else
    fail "Test 8b: state file missing/incorrect: $(cat "$state" 2>/dev/null)"
fi

if [ -f "$hold" ] && grep -q "META-9001" "$hold" && grep -q "reconcile" "$hold"; then
    ok "Test 8c: hold file records keyword → RCA gap id"
else
    fail "Test 8c: hold file missing/incorrect: $(cat "$hold" 2>/dev/null)"
fi

if grep -q "recurring_gap_pattern_rca_filed" "$amb"; then
    ok "Test 8d: ambient emits recurring_gap_pattern_rca_filed"
else
    fail "Test 8d: ambient missing recurring_gap_pattern_rca_filed event"
fi

if grep -q "TEST-001 --depends-on META-9001" "$SET_LOG" \
    && grep -q "TEST-002 --depends-on META-9001" "$SET_LOG" \
    && grep -q "TEST-003 --depends-on META-9001" "$SET_LOG"; then
    ok "Test 8e: every symptom gap got 'gap set --depends-on' the root gap"
else
    fail "Test 8e: expected 3 depends-on set calls; log: $(cat "$SET_LOG" 2>/dev/null)"
fi

# ── Test 9: RCA reflex is idempotent — repeat run doesn't refile ─────────────
echo "--- Test 9: repeat detection reuses existing RCA gap, no second reserve ---"
: > "$RESERVE_LOG"
: > "$SET_LOG"
out2=$(cd "$FAKE_REPO" && PATH="$FAKE_BIN:$PATH" CHUMP_AMBIENT_LOG="$amb" \
    CHUMP_PATTERN_DETECTOR_STATE="$state" CHUMP_PATTERN_DETECTOR_HOLD="$hold" \
    CHUMP_RCA_REFLEX_ENABLED=1 CHUMP_RCA_REFLEX_LLM_DISABLED=1 \
    "$DETECTOR" --days 7 --threshold 3 2>&1)
if [ ! -s "$RESERVE_LOG" ]; then
    ok "Test 9: second sweep reused existing RCA gap (no new reserve call)"
else
    fail "Test 9: expected no new reserve call; log: $(cat "$RESERVE_LOG")"
fi
if grep -q "TEST-001 --depends-on META-9001" "$SET_LOG"; then
    ok "Test 9b: second sweep still refreshes depends_on on symptom gaps (harmless no-op update)"
else
    fail "Test 9b: expected depends-on refresh calls even on repeat run; log: $(cat "$SET_LOG" 2>/dev/null)"
fi

# ── Test 10: --no-rca skips the reflex entirely ───────────────────────────────
echo "--- Test 10: --no-rca suppresses RCA reflex ---"
reset_repo
seed_gap "TEST-001" "$TODAY"     "orphaned lease sweep first"
seed_gap "TEST-002" "$YESTERDAY" "orphaned lease sweep second"
seed_gap "TEST-003" "$LAST_WEEK" "orphaned lease sweep third"
state2="$FAKE_REPO/.chump-locks/pattern-detector-state2.json"
hold2="$FAKE_REPO/.chump-locks/pattern-detector-hold2.json"
: > "$RESERVE_LOG"
: > "$SET_LOG"
( cd "$FAKE_REPO" && PATH="$FAKE_BIN:$PATH" CHUMP_AMBIENT_LOG="$amb" \
    CHUMP_PATTERN_DETECTOR_STATE="$state2" CHUMP_PATTERN_DETECTOR_HOLD="$hold2" \
    CHUMP_RCA_REFLEX_ENABLED=1 CHUMP_RCA_REFLEX_LLM_DISABLED=1 \
    "$DETECTOR" --days 7 --threshold 3 --no-rca >/dev/null 2>&1 )
if [ ! -s "$RESERVE_LOG" ] && [ ! -f "$state2" ] && [ ! -f "$hold2" ]; then
    ok "Test 10: --no-rca skipped gap-reserve + state/hold writes"
else
    fail "Test 10: --no-rca should skip reflex entirely (reserve log: $(cat "$RESERVE_LOG" 2>/dev/null))"
fi

# ── Test 11: CHUMP_RCA_REFLEX_ENABLED defaults OFF — no auto-file/auto-block ──
echo "--- Test 11: reflex is OFF by default (RESILIENT-365 AC6) ---"
reset_repo
seed_gap "TEST-001" "$TODAY"     "wedge detection restart first"
seed_gap "TEST-002" "$YESTERDAY" "wedge detection restart second"
seed_gap "TEST-003" "$LAST_WEEK" "wedge detection restart third"
state3="$FAKE_REPO/.chump-locks/pattern-detector-state3.json"
hold3="$FAKE_REPO/.chump-locks/pattern-detector-hold3.json"
amb3="$FAKE_REPO/.chump-locks/ambient3.jsonl"
: > "$RESERVE_LOG"
: > "$SET_LOG"
out3=$(cd "$FAKE_REPO" && PATH="$FAKE_BIN:$PATH" CHUMP_AMBIENT_LOG="$amb3" \
    CHUMP_PATTERN_DETECTOR_STATE="$state3" CHUMP_PATTERN_DETECTOR_HOLD="$hold3" \
    "$DETECTOR" --days 7 --threshold 3 2>&1)
if echo "$out3" | grep -q "CLUSTER.*wedge"; then
    ok "Test 11a: detection + ALERT still fire when reflex is OFF"
else
    fail "Test 11a: expected cluster detection to still run when reflex is OFF; output: $out3"
fi
if grep -q "recurring_gap_pattern" "$amb3"; then
    ok "Test 11b: ambient ALERT still emitted when reflex is OFF"
else
    fail "Test 11b: expected ambient ALERT even with reflex OFF"
fi
if [ ! -s "$RESERVE_LOG" ] && [ ! -s "$SET_LOG" ] && [ ! -f "$state3" ] && [ ! -f "$hold3" ]; then
    ok "Test 11c: no gap reserve/set calls and no state/hold files when CHUMP_RCA_REFLEX_ENABLED unset"
else
    fail "Test 11c: reflex should be a no-op by default; reserve=$(cat "$RESERVE_LOG" 2>/dev/null) set=$(cat "$SET_LOG" 2>/dev/null)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
