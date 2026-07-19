#!/usr/bin/env bash
# test-chumpd.sh — MISSION-051 supervisor v0
#
#  - spawns desired workers as children (mock worker fixture)
#  - respawns a killed worker within 2 ticks
#  - mode=off stops children
#  - SIGTERM takes children down with the supervisor
#  - status JSON drops with worker pids
set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chumpd"
if [[ ! -x "$BIN" ]]; then
    echo "  [build] cargo build -p chumpd..."
    (cd "$REPO_ROOT" && cargo build -p chumpd -q) || { echo "FAIL: build"; exit 1; }
fi
[[ -x "$BIN" ]] || BIN="$REPO_ROOT/target/debug/chumpd"

echo "=== MISSION-051 chumpd v0 test ==="

FIX="$(mktemp -d)"
mkdir -p "$FIX/repo/scripts/dispatch" "$FIX/repo/.chump-locks" "$FIX/repo/.chump" "$FIX/home/.chump" "$FIX/hb"
cat > "$FIX/repo/scripts/dispatch/worker.sh" <<'MOCK'
#!/usr/bin/env bash
# mock worker: heartbeat every 2s forever
while true; do
    date +%s > "${CHUMP_HEARTBEAT_DIR:-/tmp}/chump-fleet-worker-${AGENT_ID}.heartbeat"
    sleep 2
done
MOCK
chmod +x "$FIX/repo/scripts/dispatch/worker.sh"
echo grind > "$FIX/home/.chump/fleet-mode"
echo 2 > "$FIX/repo/.chump/fleet-desired-size"

HOME="$FIX/home" CHUMP_REPO="$FIX/repo" CHUMP_HEARTBEAT_DIR="$FIX/hb" \
    CHUMPD_TAKEOVER=0 "$BIN" > "$FIX/chumpd.log" 2>&1 &
DPID=$!
sleep 20

# 1. two workers spawned
spawned=$(grep -c '"kind":"chumpd_worker_spawned"' "$FIX/repo/.chump-locks/ambient.jsonl" 2>/dev/null || echo 0)
if [[ "$spawned" -ge 2 ]]; then ok "spawned >=2 workers (got $spawned)"; else fail "expected 2 spawns, got $spawned"; fi

# 2. status JSON has pids
if [[ -f /tmp/chumpd-status.json ]] && python3 -c "
import json; d=json.load(open('/tmp/chumpd-status.json'))
assert d['desired']==2 and len([w for w in d['workers'] if w['pid']])>=2" 2>/dev/null; then
    ok "status JSON shows 2 live pids"
else
    fail "status JSON missing/wrong"
fi

# 3. kill worker 1 → respawn
w1=$(python3 -c "
import json; d=json.load(open('/tmp/chumpd-status.json'))
print(next(w['pid'] for w in d['workers'] if w['id']==1))" 2>/dev/null || echo "")
if [[ -n "$w1" ]]; then
    kill -9 "$w1" 2>/dev/null
    sleep 35
    respawns=$(grep -c '"kind":"chumpd_worker_spawned"' "$FIX/repo/.chump-locks/ambient.jsonl")
    if [[ "$respawns" -ge 3 ]]; then ok "killed worker respawned (spawn events: $respawns)"; else fail "no respawn after kill (spawns: $respawns)"; fi
else
    fail "could not read worker-1 pid"
fi

# 4. mode=off stops children
echo off > "$FIX/home/.chump/fleet-mode"
sleep 20
alive=$(pgrep -f "$FIX/repo/scripts/dispatch/worker.sh" | wc -l | tr -d ' ')
if [[ "$alive" == "0" ]]; then ok "mode=off: children stopped"; else fail "mode=off left $alive children"; fi

# 5. SIGTERM → graceful stop event
echo grind > "$FIX/home/.chump/fleet-mode"
sleep 20
kill -TERM "$DPID" 2>/dev/null
sleep 18
if grep -q '"kind":"chumpd_stopped"' "$FIX/repo/.chump-locks/ambient.jsonl"; then
    ok "SIGTERM: chumpd_stopped emitted"
else
    fail "no chumpd_stopped on SIGTERM"
fi
sleep 2
alive=$(pgrep -f "$FIX/repo/scripts/dispatch/worker.sh" | wc -l | tr -d ' ')
if [[ "$alive" == "0" ]]; then ok "SIGTERM: children taken down"; else fail "children survived supervisor death ($alive)"; kill -9 $(pgrep -f "$FIX/repo/scripts/dispatch/worker.sh") 2>/dev/null; fi

kill -9 "$DPID" 2>/dev/null
rm -rf "$FIX"
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
