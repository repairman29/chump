#!/usr/bin/env bash
# test-chairman-pulse.sh — RESILIENT-331
#
# Proves chairman-pulse.sh turns per-organ structured outcome events into a
# power-output view, and specifically that it flags a "zombie-alive" organ —
# one that ran repeatedly but produced zero power (merged/closed/healed/armed)
# every cycle — the exact class the systemd "Finished <description>" log line
# can never surface (RESILIENT-331 evidence: rot-reaper ran 3x, pr-lander ran
# 9x, impossible to tell from liveness alone whether either did anything).
#
# Builds a synthetic ambient.jsonl with:
#   - rot-reaper: 3 reaper_run cycles, closed=0 requeued=0 skipped=N every time
#     -> ZOMBIE-ALIVE (ran, zero power)
#   - pr-lander: 2 pr_lander_beat cycles, armed=3 then armed=2 -> real power
#   - a gap_claimed/gap_shipped pair -> core-loop throughput measured directly
#
# Fails without the RESILIENT-331 change: scripts/chairman/chairman-pulse.sh
# does not exist on main.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PULSE="$REPO_ROOT/scripts/chairman/chairman-pulse.sh"
[[ -f "$PULSE" ]] || { echo "FAIL: $PULSE not found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

AMBIENT="$TMP/ambient.jsonl"

# Timestamps within the default 24h window, all "now-ish".
now_iso() { python3 -c "from datetime import datetime,timezone,timedelta;print((datetime.now(timezone.utc)-timedelta(minutes=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }

{
    # rot-reaper: 3 cycles, always zero power (closed/requeued 0; skipped only)
    for m in 180 120 60; do
        t="$(now_iso "$m")"
        printf '{"ts":"%s","kind":"reaper_run","reaper":"rot","status":"ok","counts":{"closed":0,"requeued":0,"skipped":2}}\n' "$t"
    done

    # pr-lander: 2 cycles, real power both times
    printf '{"ts":"%s","kind":"pr_lander_beat","armed":3,"node":"helsinki"}\n' "$(now_iso 150)"
    printf '{"ts":"%s","kind":"pr_lander_beat","armed":2,"node":"helsinki"}\n' "$(now_iso 30)"

    # organ-watchdog: 1 cycle, healed=1
    printf '{"ts":"%s","kind":"organ_watchdog_tick","healed":1,"dry_run":0}\n' "$(now_iso 90)"

    # core-loop: one gap claimed then shipped 5 minutes later
    printf '{"ts":"%s","kind":"gap_claimed","gap_id":"RESILIENT-999","session_id":"s1"}\n' "$(now_iso 100)"
    printf '{"ts":"%s","kind":"gap_shipped","gap_id":"RESILIENT-999","pr_number":1234}\n' "$(now_iso 95)"
} > "$AMBIENT"

out="$(CHUMP_AMBIENT_LOG="$AMBIENT" bash "$PULSE" --window-hours 24 --zombie-min-cycles 3 2>&1)"
rc=$?
echo "$out"
echo "--- exit=$rc ---"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "$out" | grep -qE '^rot +3 +0' && ok "rot-reaper row: cycles=3 power=0" || bad "rot-reaper row missing/wrong"
echo "$out" | grep -q 'rot.*ZOMBIE-ALIVE' && ok "rot-reaper flagged ZOMBIE-ALIVE" || bad "rot-reaper NOT flagged zombie-alive"
echo "$out" | grep -qE '^pr-lander +2 +5' && ok "pr-lander row: cycles=2 power=5 (3+2 armed)" || bad "pr-lander row missing/wrong"
echo "$out" | grep -q 'pr-lander.*ZOMBIE' && bad "pr-lander wrongly flagged zombie (it has real power)" || ok "pr-lander correctly NOT flagged zombie"
echo "$out" | grep -qE '^organ-watchdog +1 +1' && ok "organ-watchdog row: cycles=1 power=1" || bad "organ-watchdog row missing/wrong"
echo "$out" | grep -q 'ZOMBIE-ALIVE organs this window: rot' && ok "summary line names rot as zombie" || bad "summary line missing rot"
echo "$out" | grep -qE 'claimed=1 shipped_and_matched=1' && ok "core-loop throughput measured directly (claimed=1 shipped=1)" || bad "core-loop throughput line missing/wrong"

[[ "$rc" -eq 2 ]] && ok "exit code 2 signals a zombie-alive organ was found" || bad "expected exit 2 (zombie present), got $rc"

# Ambient events emitted for downstream consumers.
grep -q '"kind":"chairman_pulse_tick"' "$AMBIENT" && ok "chairman_pulse_tick emitted" || bad "chairman_pulse_tick not emitted"
grep -q '"kind":"organ_zombie_alive".*"organ":"rot"' "$AMBIENT" && ok "organ_zombie_alive emitted for rot" || bad "organ_zombie_alive not emitted for rot"

# --- Negative control: an all-healthy window must NOT flag anything and must exit 0 ---
AMBIENT2="$TMP/ambient-healthy.jsonl"
{
    printf '{"ts":"%s","kind":"reaper_run","reaper":"rot","status":"ok","counts":{"closed":1,"requeued":0,"skipped":0}}\n' "$(now_iso 60)"
    printf '{"ts":"%s","kind":"reaper_run","reaper":"rot","status":"ok","counts":{"closed":2,"requeued":0,"skipped":0}}\n' "$(now_iso 30)"
    printf '{"ts":"%s","kind":"reaper_run","reaper":"rot","status":"ok","counts":{"closed":0,"requeued":1,"skipped":0}}\n' "$(now_iso 5)"
} > "$AMBIENT2"
out2="$(CHUMP_AMBIENT_LOG="$AMBIENT2" bash "$PULSE" --window-hours 24 --zombie-min-cycles 3 2>&1)"
rc2=$?
echo "$out2" | grep -q 'no zombie-alive organs this window' && ok "healthy rot-reaper NOT flagged (real power every cycle)" || bad "healthy rot-reaper wrongly flagged"
[[ "$rc2" -eq 0 ]] && ok "healthy window exits 0" || bad "healthy window should exit 0, got $rc2"

echo "=== $pass passed, $fail failed ==="
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
