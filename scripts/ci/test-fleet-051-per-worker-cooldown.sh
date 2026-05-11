#!/usr/bin/env bash
# test-fleet-051-per-worker-cooldown.sh — FLEET-051 tests.
#
# Verifies per-worker cooldown: a failure by worker A does not block worker B
# from picking the same gap. Cluster-wide block fires only at threshold.
#
#   (1) worker.sh writes ${AGENT_ID}-${GAP_ID}.json (not ${GAP_ID}.json)
#   (2) cooled_down_gaps() in _pick_gap.py accepts worker_id parameter
#   (3) worker A cooldown does NOT appear in worker B's cooled set
#   (4) worker A cooldown DOES appear in worker A's cooled set
#   (5) legacy ${GAP_ID}.json (no leading digit) still blocks all workers
#   (6) cluster-wide block fires when distinct-worker count >= threshold (3)
#   (7) WORKER_ID env passed to _pick_and_claim_gap.py via worker.sh
#   (8) ambient event kind="worker_cooldown" emitted (not gap-wide event)
#
# Run: ./scripts/ci/test-fleet-051-per-worker-cooldown.sh

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKER_SH="$REPO_ROOT/scripts/dispatch/worker.sh"
PICK_GAP="$REPO_ROOT/scripts/dispatch/_pick_gap.py"
PICK_CLAIM="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

echo "=== FLEET-051 per-worker cooldown tests ==="
echo

# ── Test 1: worker.sh writes ${AGENT_ID}-${GAP_ID}.json ──────────────────────
echo "--- Test 1: worker.sh uses per-worker filename format ---"
if grep -q '${_safe_agent}-${GAP_ID}.json\|${AGENT_ID}-${GAP_ID}' "$WORKER_SH" 2>/dev/null; then
    ok "Test 1: worker.sh writes per-worker cooldown filename"
else
    fail "Test 1: per-worker filename not found in worker.sh"
fi

# ── Test 2: cooled_down_gaps() in _pick_gap.py accepts worker_id ─────────────
echo "--- Test 2: _pick_gap.py cooled_down_gaps() has worker_id parameter ---"
if grep -q 'def cooled_down_gaps.*worker_id' "$PICK_GAP" 2>/dev/null; then
    ok "Test 2: _pick_gap.py cooled_down_gaps() has worker_id param"
else
    fail "Test 2: worker_id param missing from _pick_gap.py cooled_down_gaps()"
fi

# ── Test 3: worker A file doesn't appear in worker B's cooled set ─────────────
echo "--- Test 3: workerA cooldown not visible to workerB ---"
_tmpdir="$(mktemp -d)"
trap 'rm -rf "$_tmpdir"' EXIT

# Create per-worker cooldown file for worker 1 on gap FLEET-TEST
_future=$(( $(date +%s) + 3600 ))
printf '{"gap_id":"FLEET-TEST","rc":1,"kind":"rc=1","until":%d,"agent":"1","worker_id":"1"}\n' \
    "$_future" > "$_tmpdir/1-FLEET-TEST.json"

# Worker 2 should NOT see FLEET-TEST cooled
_result=$(COOLDOWN_DIR="$_tmpdir" WORKER_ID="2" FLEET_COOLDOWN_THRESHOLD="3" \
    python3 - <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ.get("REPO_ROOT", ".") + "/scripts/dispatch")
from _pick_gap import cooled_down_gaps
cooled = cooled_down_gaps(
    os.environ["COOLDOWN_DIR"],
    worker_id=os.environ.get("WORKER_ID",""),
)
print("cooled" if "FLEET-TEST" in cooled else "ok")
PYEOF
)
if [[ "$_result" == "ok" ]]; then
    ok "Test 3: worker B not blocked by worker A's cooldown"
else
    fail "Test 3: worker B incorrectly blocked by worker A's cooldown"
fi

# ── Test 4: worker A's cooldown IS in worker A's cooled set ──────────────────
echo "--- Test 4: workerA cooldown visible to workerA ---"
_result=$(COOLDOWN_DIR="$_tmpdir" WORKER_ID="1" FLEET_COOLDOWN_THRESHOLD="3" \
    python3 - <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ.get("REPO_ROOT", ".") + "/scripts/dispatch")
from _pick_gap import cooled_down_gaps
cooled = cooled_down_gaps(
    os.environ["COOLDOWN_DIR"],
    worker_id=os.environ.get("WORKER_ID",""),
)
print("cooled" if "FLEET-TEST" in cooled else "not-cooled")
PYEOF
)
if [[ "$_result" == "cooled" ]]; then
    ok "Test 4: worker A sees its own cooldown"
else
    fail "Test 4: worker A does not see its own cooldown"
fi

# ── Test 5: legacy ${GAP_ID}.json (no leading digit) blocks all ──────────────
echo "--- Test 5: legacy gap-wide file blocks all workers ---"
_tmpdir2="$(mktemp -d)"
trap 'rm -rf "$_tmpdir" "$_tmpdir2"' EXIT
printf '{"gap_id":"FLEET-WIDE","rc":1,"cooldown_kind":"cluster_wide","until":%d}\n' \
    "$_future" > "$_tmpdir2/FLEET-WIDE.json"

_result=$(COOLDOWN_DIR="$_tmpdir2" WORKER_ID="2" FLEET_COOLDOWN_THRESHOLD="3" \
    python3 - <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ.get("REPO_ROOT", ".") + "/scripts/dispatch")
from _pick_gap import cooled_down_gaps
cooled = cooled_down_gaps(
    os.environ["COOLDOWN_DIR"],
    worker_id=os.environ.get("WORKER_ID",""),
)
print("blocked" if "FLEET-WIDE" in cooled else "not-blocked")
PYEOF
)
if [[ "$_result" == "blocked" ]]; then
    ok "Test 5: legacy gap-wide cooldown blocks all workers"
else
    fail "Test 5: legacy gap-wide cooldown did not block worker"
fi

# ── Test 6: cluster-wide block fires at threshold ─────────────────────────────
echo "--- Test 6: cluster-wide block fires at FLEET_COOLDOWN_THRESHOLD distinct workers ---"
_tmpdir3="$(mktemp -d)"
trap 'rm -rf "$_tmpdir" "$_tmpdir2" "$_tmpdir3"' EXIT
for _w in 1 2 3; do
    printf '{"gap_id":"FLEET-THRESH","rc":1,"kind":"rc=1","until":%d,"agent":"%s","worker_id":"%s"}\n' \
        "$_future" "$_w" "$_w" > "$_tmpdir3/${_w}-FLEET-THRESH.json"
done

_result=$(COOLDOWN_DIR="$_tmpdir3" WORKER_ID="4" FLEET_COOLDOWN_THRESHOLD="3" \
    python3 - <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ.get("REPO_ROOT", ".") + "/scripts/dispatch")
from _pick_gap import cooled_down_gaps
cooled = cooled_down_gaps(
    os.environ["COOLDOWN_DIR"],
    worker_id=os.environ.get("WORKER_ID",""),
)
print("cluster-blocked" if "FLEET-THRESH" in cooled else "not-blocked")
PYEOF
)
if [[ "$_result" == "cluster-blocked" ]]; then
    ok "Test 6: cluster-wide block fires at threshold=3 distinct workers"
else
    fail "Test 6: cluster-wide block did not fire at threshold=3"
fi

# ── Test 7: WORKER_ID env passed to _pick_and_claim_gap.py call ──────────────
echo "--- Test 7: WORKER_ID passed to _pick_and_claim_gap.py in worker.sh ---"
if grep -q 'WORKER_ID.*AGENT_ID\|WORKER_ID="$AGENT_ID"' "$WORKER_SH" 2>/dev/null; then
    ok "Test 7: WORKER_ID env var passed when invoking _pick_and_claim_gap.py"
else
    fail "Test 7: WORKER_ID not passed to _pick_and_claim_gap.py"
fi

# ── Test 8: ambient event kind="worker_cooldown" in worker.sh ────────────────
echo "--- Test 8: worker.sh emits kind=worker_cooldown ambient event ---"
if grep -q 'worker_cooldown' "$WORKER_SH" 2>/dev/null; then
    ok "Test 8: kind=worker_cooldown ambient event present in worker.sh"
else
    fail "Test 8: kind=worker_cooldown ambient event missing from worker.sh"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
