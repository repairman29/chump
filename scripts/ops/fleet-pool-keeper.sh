#!/usr/bin/env bash
# fleet-pool-keeper.sh — RESILIENT-177: the fleet's missing survival organ.
#
# Nobody owned "workers must exist when mode says grind": the farmer revives
# panes in an EXISTING tmux session, wake-recovery fires only on wake, and
# keepalive keeps ollama alive. A dead tmux server (hibernate, memory
# pressure, whatever killed it four times on 2026-07-19) was invisible to all
# three, so every sudden death became permanent until a human noticed.
#
# Runs every CHUMP_POOL_KEEPER_INTERVAL_S (launchd, 300s). Logic:
#   mode == off                 → do nothing
#   alive workers >= 1          → do nothing (partial degradation is the
#                                 farmer's lane; this daemon owns TOTAL death)
#   alive == 0                  → relaunch fleet at mode size, emit
#                                 kind=fleet_pool_restored
#   cooldown 600s between restores; >3 restores/hour → emit escalated=true
#   and STOP restoring (a persistent killer needs a human, not a thrash loop)
#
# Liveness = worker heartbeat files fresher than HEARTBEAT_FRESH_S (180s) —
# robust to pgrep-pattern drift across launcher styles (the chumpbar counting
# bug of 2026-07-19).
#
# Rust-First-Bypass: launchctl/stat/date glue over existing chump-mode; the
# durable home is chumpd's supervisor (MISSION-051) which retires this daemon.

set -uo pipefail

# launchd spawns with PATH=/usr/bin:/bin — tmux/chump live in homebrew and
# ~/.local; without this the relaunch is a silent no-op while chump-mode still
# prints its success banner (observed on the keeper's very first live firing,
# 2026-07-19 21:20Z).
export PATH="/opt/homebrew/bin:$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:$PATH"

REPO="${CHUMP_REPO:-$HOME/Projects/Chump}"
MODE_FILE="${CHUMP_MODE_FILE:-$HOME/.chump/fleet-mode}"
AMBIENT="${REPO}/.chump-locks/ambient.jsonl"
STATE="$HOME/.chump/pool-keeper-state.json"
HB_GLOB="/tmp/chump-fleet-worker-*.heartbeat"
HEARTBEAT_FRESH_S="${CHUMP_POOL_KEEPER_HB_FRESH_S:-180}"
COOLDOWN_S="${CHUMP_POOL_KEEPER_COOLDOWN_S:-600}"
STORM_LIMIT="${CHUMP_POOL_KEEPER_STORM_LIMIT:-3}"
CHUMP_MODE_BIN="${CHUMP_MODE_BIN:-$HOME/.local/bin/chump-mode}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now=$(date +%s)

mode="$(cat "$MODE_FILE" 2>/dev/null || echo off)"
[[ "$mode" == "off" || -z "$mode" ]] && exit 0

# ── liveness via heartbeat freshness ─────────────────────────────────────────
alive=0
for hb in $HB_GLOB; do
    [[ -f "$hb" ]] || continue
    hb_age=$(( now - $(stat -f %m "$hb" 2>/dev/null || echo 0) ))
    (( hb_age <= HEARTBEAT_FRESH_S )) && alive=$((alive + 1))
done
(( alive >= 1 )) && exit 0

# ── total death confirmed — consult cooldown + storm state ───────────────────
last_restore=0
restores_this_hour=0
if [[ -f "$STATE" ]]; then
    last_restore="$(python3 -c "import json;print(json.load(open('$STATE')).get('last_restore',0))" 2>/dev/null || echo 0)"
    restores_this_hour="$(python3 -c "
import json,sys
d=json.load(open('$STATE'))
cutoff=$now-3600
print(len([t for t in d.get('restores',[]) if t>cutoff]))" 2>/dev/null || echo 0)"
fi

if (( now - last_restore < COOLDOWN_S )); then
    exit 0
fi

emit() {
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '%s\n' "$1" >> "$AMBIENT" 2>/dev/null || true
}

if (( restores_this_hour >= STORM_LIMIT )); then
    # scanner-anchor: "kind":"fleet_pool_restored"
    emit "{\"ts\":\"$(ts)\",\"kind\":\"fleet_pool_restored\",\"mode\":\"$mode\",\"restored\":false,\"escalated\":true,\"note\":\"RESILIENT-177: ${restores_this_hour} restores in the last hour — persistent killer, refusing to thrash; operator attention needed\"}"
    exit 0
fi

# ── relaunch at mode size ────────────────────────────────────────────────────
relaunch_out="$("$CHUMP_MODE_BIN" "$mode" 2>&1 | tail -1 || true)"

# Verify the relaunch actually took: wait for a fresh heartbeat (workers write
# within ~60s of spawn). chump-mode's banner is a CLAIM; heartbeats are the
# observation (CREDIBLE-154 discipline applies to the keeper itself).
relaunch_ok=false
if [[ "${CHUMP_POOL_KEEPER_SKIP_VERIFY:-0}" != "1" ]]; then
    for _i in 1 2 3 4 5 6 7 8 9; do
        sleep 10
        for hb in $HB_GLOB; do
            [[ -f "$hb" ]] || continue
            hb_age=$(( $(date +%s) - $(stat -f %m "$hb" 2>/dev/null || echo 0) ))
            (( hb_age <= 60 )) && relaunch_ok=true && break 2
        done
    done
else
    relaunch_ok=true
fi

python3 - "$STATE" "$now" <<'PY'
import json, sys, os
p, now = sys.argv[1], int(sys.argv[2])
d = {"restores": []}
if os.path.exists(p):
    try: d = json.load(open(p))
    except Exception: pass
d.setdefault("restores", []).append(now)
d["restores"] = [t for t in d["restores"] if t > now - 7200]
d["last_restore"] = now
json.dump(d, open(p, "w"))
PY

if [[ "$relaunch_ok" == "true" ]]; then
    emit "{\"ts\":\"$(ts)\",\"kind\":\"fleet_pool_restored\",\"mode\":\"$mode\",\"restored\":true,\"escalated\":false,\"note\":\"RESILIENT-177: zero live worker heartbeats with mode=$mode — fleet relaunched and heartbeat verified\"}"
    echo "[pool-keeper] $(ts) restored fleet (mode=$mode): $relaunch_out"
else
    emit "{\"ts\":\"$(ts)\",\"kind\":\"fleet_pool_restored\",\"mode\":\"$mode\",\"restored\":false,\"escalated\":false,\"note\":\"RESILIENT-177: relaunch invoked but NO fresh heartbeat within 90s — relaunch failed (PATH? tmux? see /tmp/chump-fleet-pool-keeper.log)\"}"
    echo "[pool-keeper] $(ts) RELAUNCH FAILED (mode=$mode): no heartbeat within 90s; out: $relaunch_out"
fi
