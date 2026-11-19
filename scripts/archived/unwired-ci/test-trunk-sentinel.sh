#!/usr/bin/env bash
# Smoke test for trunk-sentinel-daemon. Asserts:
#   (a) script is executable
#   (b) --help exits 0 and prints header
#   (c) tick with synthetic GREEN fixture → state=TRUNK_GREEN, no gap filed
#   (d) tick with synthetic RED fixture (fresh) → kind=trunk_state_change (GREEN→RED)
#   (e) re-tick with same RED fixture → NO duplicate trunk_red_persistent for same fp
#   (f) tick with GREEN fixture after RED → kind=trunk_recovered
#   (g) fingerprint is deterministic across two ticks with same failing jobs.
#
# All ticks run with CHUMP_TRUNK_SENTINEL_DRY_RUN=1 to avoid chump gap reserve
# and gh writes. We use CHUMP_TRUNK_SENTINEL_MOCK_RUN_JSON to inject fixtures.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DAEMON="$REPO_ROOT/scripts/coord/trunk-sentinel-daemon.sh"

WORK_DIR="$(mktemp -d /tmp/trunk-sentinel-test-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

AMBIENT="$WORK_DIR/ambient.jsonl"
STATE_FILE="$WORK_DIR/state.json"
GREEN_FIXTURE="$WORK_DIR/run-green.json"
RED_FIXTURE_A="$WORK_DIR/run-red-a.json"
RED_FIXTURE_B="$WORK_DIR/run-red-b.json"

cat > "$GREEN_FIXTURE" <<'EOF'
{"run_id":1001,"head_sha":"abc123","conclusion":"success","status":"completed","created_at":"2026-05-31T00:00:00Z","html_url":"https://x","failing_jobs":""}
EOF

cat > "$RED_FIXTURE_A" <<'EOF'
{"run_id":1002,"head_sha":"def456","conclusion":"failure","status":"completed","created_at":"2026-05-31T00:05:00Z","html_url":"https://x","failing_jobs":"fast-checks,gap-status-check"}
EOF

cat > "$RED_FIXTURE_B" <<'EOF'
{"run_id":1003,"head_sha":"ghi789","conclusion":"failure","status":"completed","created_at":"2026-05-31T00:10:00Z","html_url":"https://x","failing_jobs":"clippy"}
EOF

export CHUMP_TRUNK_SENTINEL_DRY_RUN=1
export CHUMP_AMBIENT_PATH="$AMBIENT"
export CHUMP_TRUNK_SENTINEL_STATE_FILE="$STATE_FILE"
# Force the file-bucket on first RED so we exercise the gap-file path:
export CHUMP_TRUNK_SENTINEL_RED_FILE_S=0
export CHUMP_TRUNK_SENTINEL_RED_DISPATCH_S=99999
export CHUMP_TRUNK_SENTINEL_RED_RECALL_S=99999

# ── (a) executable ────────────────────────────────────────────────────────────
[[ -x "$DAEMON" ]] || { echo "[test] FAIL: daemon not executable"; exit 1; }
echo "[test] (a) executable: OK"

# ── (b) --help ────────────────────────────────────────────────────────────────
help_out="$("$DAEMON" --help 2>&1)" || { echo "[test] FAIL: --help non-zero"; exit 1; }
echo "$help_out" | grep -q 'Trunk Health Sentinel' || { echo "[test] FAIL: --help missing header"; exit 1; }
echo "[test] (b) --help: OK"

# ── (c) GREEN fixture ─────────────────────────────────────────────────────────
CHUMP_TRUNK_SENTINEL_MOCK_RUN_JSON="$GREEN_FIXTURE" "$DAEMON" tick 2>/dev/null \
    || { echo "[test] FAIL: green tick non-zero"; exit 1; }
grep -q '"state":"TRUNK_GREEN"' "$AMBIENT" \
    || { echo "[test] FAIL: no TRUNK_GREEN tick event"; exit 1; }
if grep -q '"kind":"trunk_red_persistent"' "$AMBIENT"; then
    echo "[test] FAIL: GREEN fixture should not file gap"; exit 1
fi
echo "[test] (c) GREEN fixture: OK"

# ── (d) RED fixture A (fresh) ─────────────────────────────────────────────────
before=$(wc -l < "$AMBIENT")
CHUMP_TRUNK_SENTINEL_MOCK_RUN_JSON="$RED_FIXTURE_A" "$DAEMON" tick 2>/dev/null \
    || { echo "[test] FAIL: red tick A non-zero"; exit 1; }
after=$(wc -l < "$AMBIENT")
[[ "$after" -gt "$before" ]] || { echo "[test] FAIL: no event appended for RED"; exit 1; }
new_lines=$(tail -n +"$((before + 1))" "$AMBIENT")
echo "$new_lines" | grep -q '"kind":"trunk_state_change"' \
    || { echo "[test] FAIL: no trunk_state_change for GREEN→RED"; exit 1; }
echo "$new_lines" | grep '"kind":"trunk_state_change"' | grep -q '"to":"TRUNK_RED"' \
    || { echo "[test] FAIL: trunk_state_change missing to=TRUNK_RED"; exit 1; }
echo "$new_lines" | grep -q '"kind":"trunk_red_persistent"' \
    || { echo "[test] FAIL: no trunk_red_persistent at 5min bucket"; exit 1; }
echo "[test] (d) RED fresh fixture: OK"

# Capture the fingerprint for idempotency comparison.
fp_a=$(echo "$new_lines" | grep '"kind":"trunk_red_persistent"' | head -1 \
    | python3 -c "import json,sys; print(json.loads(sys.stdin.read().strip()).get('fingerprint',''))")
[[ -n "$fp_a" ]] || { echo "[test] FAIL: trunk_red_persistent missing fingerprint"; exit 1; }

# ── (e) RED fixture A again (idempotency) ─────────────────────────────────────
before2=$(wc -l < "$AMBIENT")
CHUMP_TRUNK_SENTINEL_MOCK_RUN_JSON="$RED_FIXTURE_A" "$DAEMON" tick 2>/dev/null \
    || { echo "[test] FAIL: red tick A re-run non-zero"; exit 1; }
after2=$(wc -l < "$AMBIENT")
new_lines2=$(tail -n +"$((before2 + 1))" "$AMBIENT")

# trunk_sentinel_tick is expected (every tick), but trunk_red_persistent should NOT repeat
# for the same fingerprint.
repeat_count=$(echo "$new_lines2" | grep '"kind":"trunk_red_persistent"' | grep -c "\"fingerprint\":\"$fp_a\"" || true)
if [[ "$repeat_count" -gt 0 ]]; then
    echo "[test] FAIL: trunk_red_persistent re-emitted for same fingerprint $fp_a (dedup broken)"; exit 1
fi
echo "[test] (e) idempotent re-tick (fp=$fp_a): OK"

# ── (g) fingerprint determinism across ticks ─────────────────────────────────
# Run an isolated tick with a fresh state file to confirm same failing-jobs CSV
# yields the same fingerprint.
STATE_FILE2="$WORK_DIR/state2.json"
AMBIENT2="$WORK_DIR/ambient2.jsonl"
CHUMP_TRUNK_SENTINEL_STATE_FILE="$STATE_FILE2" \
CHUMP_AMBIENT_PATH="$AMBIENT2" \
CHUMP_TRUNK_SENTINEL_MOCK_RUN_JSON="$RED_FIXTURE_A" \
    "$DAEMON" tick 2>/dev/null || { echo "[test] FAIL: isolated tick non-zero"; exit 1; }
fp_a_dup=$(grep '"kind":"trunk_red_persistent"' "$AMBIENT2" | head -1 \
    | python3 -c "import json,sys; print(json.loads(sys.stdin.read().strip()).get('fingerprint',''))")
if [[ "$fp_a" != "$fp_a_dup" ]]; then
    echo "[test] FAIL: fingerprint not deterministic ($fp_a vs $fp_a_dup)"; exit 1
fi
echo "[test] (g) fingerprint deterministic: OK (fp=$fp_a)"

# ── (f) recovery (RED→GREEN) ──────────────────────────────────────────────────
before3=$(wc -l < "$AMBIENT")
CHUMP_TRUNK_SENTINEL_MOCK_RUN_JSON="$GREEN_FIXTURE" "$DAEMON" tick 2>/dev/null \
    || { echo "[test] FAIL: recovery tick non-zero"; exit 1; }
new_lines3=$(tail -n +"$((before3 + 1))" "$AMBIENT")
echo "$new_lines3" | grep -q '"kind":"trunk_recovered"' \
    || { echo "[test] FAIL: no trunk_recovered event on RED→GREEN"; exit 1; }
echo "$new_lines3" | grep '"kind":"trunk_state_change"' | grep -q '"to":"TRUNK_GREEN"' \
    || { echo "[test] FAIL: no trunk_state_change to TRUNK_GREEN"; exit 1; }
echo "[test] (f) recovery RED→GREEN: OK"

# Verify state file resets after recovery.
if [[ -f "$STATE_FILE" ]]; then
    state_after=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['state'])")
    [[ "$state_after" == "TRUNK_GREEN" ]] \
        || { echo "[test] FAIL: state file not reset after recovery (state=$state_after)"; exit 1; }
fi

# ── (h) RESILIENT-097 recovery via RED→AMBER→GREEN path ──────────────────────
# Regression test for the 2026-06-05 leak: 23 trunk-red zombies accumulated
# because the recover gate was `prev_state == TRUNK_RED`, which skipped
# transitions where the sentinel briefly observed AMBER between the red
# event and the recovery. The new gate fires whenever cur_state=GREEN AND
# the persisted filed_gaps list is non-empty.
#
# Setup: drive state back to RED, transition to AMBER (in-progress run with
# no conclusion yet), then GREEN; confirm trunk_recovered still fires.
AMBER_FIXTURE="$WORK_DIR/run-amber.json"
cat > "$AMBER_FIXTURE" <<'EOF'
{"run_id":1004,"head_sha":"amb000","conclusion":"","status":"in_progress","created_at":"2026-05-31T00:20:00Z","html_url":"https://x","failing_jobs":""}
EOF

# Drive to RED with fixture B (new fp so file gate trips again)
CHUMP_TRUNK_SENTINEL_MOCK_RUN_JSON="$RED_FIXTURE_B" "$DAEMON" tick 2>/dev/null \
    || { echo "[test] FAIL: (h) RED tick non-zero"; exit 1; }
state_at_red=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['state'])")
[[ "$state_at_red" == "TRUNK_RED" ]] \
    || { echo "[test] FAIL: (h) expected TRUNK_RED, got $state_at_red"; exit 1; }

# Transition to AMBER (in_progress)
CHUMP_TRUNK_SENTINEL_MOCK_RUN_JSON="$AMBER_FIXTURE" "$DAEMON" tick 2>/dev/null \
    || { echo "[test] FAIL: (h) AMBER tick non-zero"; exit 1; }
state_at_amber=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['state'])")
[[ "$state_at_amber" == "TRUNK_AMBER" ]] \
    || { echo "[test] FAIL: (h) expected TRUNK_AMBER, got $state_at_amber"; exit 1; }

# Transition AMBER→GREEN; trunk_recovered MUST fire (pre-fix behavior skipped this)
before_h=$(wc -l < "$AMBIENT")
CHUMP_TRUNK_SENTINEL_MOCK_RUN_JSON="$GREEN_FIXTURE" "$DAEMON" tick 2>/dev/null \
    || { echo "[test] FAIL: (h) GREEN-after-AMBER tick non-zero"; exit 1; }
new_h=$(tail -n +"$((before_h + 1))" "$AMBIENT")
echo "$new_h" | grep -q '"kind":"trunk_recovered"' \
    || { echo "[test] FAIL: (h) RESILIENT-097 regressed — no trunk_recovered on RED→AMBER→GREEN"; exit 1; }
echo "[test] (h) RESILIENT-097 RED→AMBER→GREEN recovery: OK"

echo "[test-trunk-sentinel] PASS"
