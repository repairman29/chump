#!/usr/bin/env bash
# test-fleet-pool-keeper.sh — RESILIENT-177
#
# The keeper owns TOTAL fleet death:
#  - mode=off            → no relaunch
#  - fresh heartbeats    → no relaunch
#  - zero heartbeats     → relaunch via CHUMP_MODE_BIN + fleet_pool_restored
#  - cooldown            → no double-relaunch within COOLDOWN_S
#  - storm               → >=STORM_LIMIT restores/hour → escalated, no relaunch
#  - installer refuses temp paths (RESILIENT-168 guard)
set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEEPER="$REPO_ROOT/scripts/ops/fleet-pool-keeper.sh"

echo "=== RESILIENT-177 fleet-pool-keeper test ==="

run_keeper() {
    # $1=mode  $2=hb_dir(unused; heartbeats are global — we isolate via glob override)
    CHUMP_REPO="$FIX" HOME="$FIX" \
    CHUMP_MODE_FILE="$FIX/fleet-mode" \
    CHUMP_MODE_BIN="$FIX/mock-chump-mode" \
    bash "$KEEPER"
}

fresh_fixture() {
    FIX="$(mktemp -d)"
    mkdir -p "$FIX/.chump-locks" "$FIX/.chump"
    cat > "$FIX/mock-chump-mode" <<'EOF'
#!/usr/bin/env bash
echo "mock relaunch: $1" >> "${HOME}/mock-calls.log"
echo "fleet up"
EOF
    chmod +x "$FIX/mock-chump-mode"
}

# NOTE: the keeper reads real /tmp/chump-fleet-worker-*.heartbeat globs.
# To avoid interference from a live fleet, tests that need "zero heartbeats"
# temporarily rename any real ones — restored via trap.
_moved=()
hide_heartbeats() {
    for hb in /tmp/chump-fleet-worker-*.heartbeat; do
        [[ -f "$hb" ]] || continue
        mv "$hb" "$hb.testhide" && _moved+=("$hb")
    done
}
restore_heartbeats() {
    for hb in "${_moved[@]:-}"; do
        [[ -f "$hb.testhide" ]] && mv "$hb.testhide" "$hb"
    done
    _moved=()
}
trap restore_heartbeats EXIT

# ── 1. mode=off → no action ──────────────────────────────────────────────────
fresh_fixture
echo off > "$FIX/fleet-mode"
hide_heartbeats
run_keeper off >/dev/null 2>&1
if [[ ! -f "$FIX/mock-calls.log" ]]; then
    ok "mode=off: no relaunch"
else
    fail "mode=off should not relaunch"
fi
restore_heartbeats
rm -rf "$FIX"

# ── 2. fresh heartbeat → no action ───────────────────────────────────────────
fresh_fixture
echo grind > "$FIX/fleet-mode"
touch /tmp/chump-fleet-worker-testfixture.heartbeat
run_keeper grind >/dev/null 2>&1
if [[ ! -f "$FIX/mock-calls.log" ]]; then
    ok "fresh heartbeat: no relaunch"
else
    fail "fresh heartbeat should suppress relaunch"
fi
rm -f /tmp/chump-fleet-worker-testfixture.heartbeat
rm -rf "$FIX"

# ── 3. zero heartbeats + grind → relaunch + event ────────────────────────────
fresh_fixture
echo grind > "$FIX/fleet-mode"
hide_heartbeats
run_keeper grind >/dev/null 2>&1
if grep -q 'mock relaunch: grind' "$FIX/mock-calls.log" 2>/dev/null; then
    ok "total death: relaunched at mode"
else
    fail "total death should relaunch via CHUMP_MODE_BIN"
fi
if grep -q '"kind":"fleet_pool_restored"' "$FIX/.chump-locks/ambient.jsonl" 2>/dev/null && \
   grep -q '"restored":true' "$FIX/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "emits fleet_pool_restored restored=true"
else
    fail "missing fleet_pool_restored event"
fi

# ── 4. cooldown → second run does nothing ────────────────────────────────────
run_keeper grind >/dev/null 2>&1
if [[ "$(grep -c 'mock relaunch' "$FIX/mock-calls.log")" == "1" ]]; then
    ok "cooldown: no double-relaunch"
else
    fail "cooldown should prevent immediate second relaunch"
fi

# ── 5. storm → escalated, no relaunch ────────────────────────────────────────
now=$(date +%s)
python3 -c "
import json
json.dump({'restores':[$now-3000,$now-2000,$now-1000],'last_restore':$now-1000}, open('$FIX/.chump/pool-keeper-state.json','w'))"
run_keeper grind >/dev/null 2>&1
if grep -q '"escalated":true' "$FIX/.chump-locks/ambient.jsonl" 2>/dev/null && \
   [[ "$(grep -c 'mock relaunch' "$FIX/mock-calls.log")" == "1" ]]; then
    ok "storm: escalated=true and refused to thrash"
else
    fail "storm limit should escalate instead of relaunching"
fi
restore_heartbeats
rm -rf "$FIX"

# ── 6. installer refuses temp paths ──────────────────────────────────────────
TMPCOPY="$(mktemp -d)/chump"
mkdir -p "$TMPCOPY/scripts/setup" "$TMPCOPY/scripts/ops"
cp "$REPO_ROOT/scripts/setup/install-fleet-pool-keeper.sh" "$TMPCOPY/scripts/setup/"
cp "$REPO_ROOT/scripts/ops/fleet-pool-keeper.sh" "$TMPCOPY/scripts/ops/"
if bash "$TMPCOPY/scripts/setup/install-fleet-pool-keeper.sh" >/dev/null 2>&1; then
    fail "installer should refuse temp path"
else
    ok "installer refuses temp path (RESILIENT-168 guard)"
fi
rm -rf "$(dirname "$TMPCOPY")"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
