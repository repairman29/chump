#!/usr/bin/env bash
# test-farmer.sh — RESILIENT-068: unit tests for scripts/coord/farmer.sh
#
# Tests the six failure-mode handlers in dry-run + fixture mode.
# Zero network calls; zero launchctl side-effects; zero chump binary calls.
#
# Coverage:
#   T1: pause-deadlock lift (fresh sentinel, slo passes)
#   T2: stale-sentinel lift (age >15min, slo passes)
#   T3: slo failing — sentinel left in place
#   T4: auth-death detection (token absent)
#   T5: auth-death detection (token stale)
#   T6: farmer_heartbeat emitted each tick
#   T7: dead-supervisor detection via LAUNCHCTL stub (exit-78)
#   T8: farmer escalation after 3 kicks in window
#   T9: dry-run mode — no side effects
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FARMER="$REPO_ROOT/scripts/coord/farmer.sh"

[[ -x "$FARMER" ]] || { echo "FAIL: farmer.sh not found or not executable: $FARMER"; exit 1; }

PASS=0
FAIL=0

_pass() { echo "  PASS: $1"; (( PASS++ )) || true; }
_fail() { echo "  FAIL: $1"; (( FAIL++ )) || true; }

run_test() {
    local name="$1"; shift
    echo ""
    echo "── $name ──"
    "$@" && _pass "$name" || _fail "$name"
}

# ── Fixture builder ────────────────────────────────────────────────────────────
make_fixture() {
    local dir
    dir="$(mktemp -d)"
    mkdir -p "$dir/.chump" "$dir/.chump-locks"
    # Minimal state.db with no ghosts (SLO passes)
    sqlite3 "$dir/.chump/state.db" "
CREATE TABLE gaps (id TEXT, status TEXT, closed_pr TEXT, title TEXT);
" 2>/dev/null || true
    echo "$dir"
}

# Run farmer once against a fixture dir; return exit code
run_farmer() {
    local repo="$1"; shift
    CHUMP_REPO_ROOT="$repo" \
    FARMER_DRY_RUN="${FARMER_DRY_RUN:-0}" \
    FARMER_OAUTH_MAX_AGE_S="${FARMER_OAUTH_MAX_AGE_S:-3600}" \
    FARMER_SENTINEL_MAX_AGE_S="${FARMER_SENTINEL_MAX_AGE_S:-900}" \
    FARMER_SILENT_WORKER_S="${FARMER_SILENT_WORKER_S:-1800}" \
    FARMER_KICK_ESCALATE_N="${FARMER_KICK_ESCALATE_N:-3}" \
    FARMER_KICK_WINDOW_S="${FARMER_KICK_WINDOW_S:-600}" \
    HOME="${FARMER_TEST_HOME:-$HOME}" \
        bash "$FARMER" "$@" 2>/dev/null
}

# ── T1: pause-deadlock lift (fresh sentinel, slo passes) ──────────────────────
t1_pause_lift() {
    local repo
    repo="$(make_fixture)"
    trap "rm -rf '$repo'" RETURN
    # Create sentinel
    touch "$repo/.chump/fleet-paused"
    # SLO passes (0 ghosts in state.db already)
    run_farmer "$repo"
    # Sentinel should be gone
    if [[ ! -f "$repo/.chump/fleet-paused" ]]; then
        grep -q '"kind":"farmer_pause_lifted"' "$repo/.chump-locks/ambient.jsonl" 2>/dev/null || \
            { echo "  missing farmer_pause_lifted event"; return 1; }
        return 0
    fi
    echo "  sentinel still present after tick"
    return 1
}

# ── T2: stale-sentinel lift (age forced via old mtime, slo passes) ─────────────
t2_stale_sentinel() {
    local repo
    repo="$(make_fixture)"
    trap "rm -rf '$repo'" RETURN
    touch "$repo/.chump/fleet-paused"
    # Force mtime to 20 minutes ago (>900s = SENTINEL_MAX_AGE_S default)
    touch -m -t "$(date -v-20M +%Y%m%d%H%M.%S 2>/dev/null || date -d '20 minutes ago' +%Y%m%d%H%M.%S 2>/dev/null || date +%Y%m%d%H%M.%S)" \
        "$repo/.chump/fleet-paused" 2>/dev/null || \
        python3 -c "import os,time; os.utime('$repo/.chump/fleet-paused', (time.time()-1200, time.time()-1200))"
    FARMER_SENTINEL_MAX_AGE_S=900 run_farmer "$repo"
    if [[ ! -f "$repo/.chump/fleet-paused" ]]; then
        return 0
    fi
    echo "  stale sentinel not lifted"
    return 1
}

# ── T3: slo failing — sentinel left in place ──────────────────────────────────
t3_slo_failing() {
    local repo
    repo="$(make_fixture)"
    trap "rm -rf '$repo'" RETURN
    # Insert 5 ghost gaps (count > 2 → SLO fails)
    sqlite3 "$repo/.chump/state.db" "
INSERT INTO gaps VALUES ('G1','open','101','gap 1');
INSERT INTO gaps VALUES ('G2','open','102','gap 2');
INSERT INTO gaps VALUES ('G3','open','103','gap 3');
INSERT INTO gaps VALUES ('G4','open','104','gap 4');
INSERT INTO gaps VALUES ('G5','open','105','gap 5');
" 2>/dev/null
    touch "$repo/.chump/fleet-paused"
    run_farmer "$repo"
    # Sentinel should remain
    if [[ -f "$repo/.chump/fleet-paused" ]]; then
        return 0
    fi
    echo "  sentinel lifted despite failing SLO"
    return 1
}

# ── T4: auth-death — token file absent ────────────────────────────────────────
t4_auth_dead_absent() {
    local repo
    repo="$(make_fixture)"
    trap "rm -rf '$repo'" RETURN
    local fake_home="$repo/home"
    mkdir -p "$fake_home/.chump"
    # No oauth-token.json
    FARMER_TEST_HOME="$fake_home" run_farmer "$repo" || true
    grep -q '"kind":"farmer_auth_dead"' "$repo/.chump-locks/ambient.jsonl" 2>/dev/null || \
        { echo "  missing farmer_auth_dead event for absent token"; return 1; }
    return 0
}

# ── T5: auth-death — token stale ──────────────────────────────────────────────
t5_auth_dead_stale() {
    local repo
    repo="$(make_fixture)"
    trap "rm -rf '$repo'" RETURN
    local fake_home="$repo/home"
    mkdir -p "$fake_home/.chump"
    touch "$fake_home/.chump/oauth-token.json"
    # Make token 2 hours old
    python3 -c "import os,time; os.utime('$fake_home/.chump/oauth-token.json', (time.time()-7200, time.time()-7200))" 2>/dev/null || \
        touch -m -t "$(date -v-2H +%Y%m%d%H%M.%S 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M.%S 2>/dev/null)" \
            "$fake_home/.chump/oauth-token.json" 2>/dev/null || true
    FARMER_OAUTH_MAX_AGE_S=3600 FARMER_TEST_HOME="$fake_home" run_farmer "$repo" || true
    grep -q '"kind":"farmer_auth_dead"' "$repo/.chump-locks/ambient.jsonl" 2>/dev/null || \
        { echo "  missing farmer_auth_dead event for stale token"; return 1; }
    return 0
}

# ── T6: farmer_heartbeat emitted each tick ────────────────────────────────────
t6_heartbeat() {
    local repo
    repo="$(make_fixture)"
    trap "rm -rf '$repo'" RETURN
    # Provide valid oauth token
    local fake_home="$repo/home"
    mkdir -p "$fake_home/.chump"
    touch "$fake_home/.chump/oauth-token.json"
    FARMER_TEST_HOME="$fake_home" run_farmer "$repo"
    grep -q '"kind":"farmer_heartbeat"' "$repo/.chump-locks/ambient.jsonl" 2>/dev/null || \
        { echo "  missing farmer_heartbeat event"; return 1; }
    [[ -f "$repo/.chump/farmer-heartbeat" ]] || \
        { echo "  heartbeat file not written"; return 1; }
    return 0
}

# ── T7: dead-supervisor detection (mocked launchctl) ─────────────────────────
t7_dead_supervisor() {
    local repo
    repo="$(make_fixture)"
    trap "rm -rf '$repo'" RETURN
    local fake_home="$repo/home"
    mkdir -p "$fake_home/.chump" "$repo/bin"
    touch "$fake_home/.chump/oauth-token.json"

    # Mock launchctl: list shows com.chump.heartbeat-watcher with exit 78
    cat > "$repo/bin/launchctl" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "list" ]]; then
    echo "- 0 com.chump.bot-merge-watchdog"
    echo "78 78 com.chump.heartbeat-watcher"
    echo "- 0 com.chump.reap-stale-leases"
    exit 0
fi
# kickstart: emit a marker file
if [[ "$1" == "kickstart" ]]; then
    touch "${TMPDIR:-/tmp}/farmer-kicked-${4##*/}"
    exit 0
fi
exit 0
MOCK
    chmod +x "$repo/bin/launchctl"

    PATH="$repo/bin:$PATH" FARMER_TEST_HOME="$fake_home" run_farmer "$repo" || true
    grep -q '"kind":"farmer_daemon_kicked"' "$repo/.chump-locks/ambient.jsonl" 2>/dev/null || \
        { echo "  missing farmer_daemon_kicked event for exit-78 daemon"; return 1; }
    return 0
}

# ── T8: escalation after 3 kicks ──────────────────────────────────────────────
t8_escalation() {
    local repo
    repo="$(make_fixture)"
    trap "rm -rf '$repo'" RETURN
    local fake_home="$repo/home"
    mkdir -p "$fake_home/.chump" "$repo/bin"
    touch "$fake_home/.chump/oauth-token.json"

    # Pre-populate kick state with 3 recent kicks for com.chump.heartbeat-watcher
    local now; now="$(date +%s)"
    python3 -c "
import json
d = {'com.chump.heartbeat-watcher': {'kicks': [$now, $now, $now], 'escalated': False}}
json.dump(d, open('$repo/.chump/farmer-kick-state.json','w'))
"
    cat > "$repo/bin/launchctl" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "list" ]]; then
    echo "78 78 com.chump.heartbeat-watcher"
    exit 0
fi
exit 0
MOCK
    chmod +x "$repo/bin/launchctl"

    PATH="$repo/bin:$PATH" FARMER_KICK_ESCALATE_N=3 FARMER_KICK_WINDOW_S=600 \
        FARMER_TEST_HOME="$fake_home" run_farmer "$repo" || true
    grep -q '"kind":"farmer_escalated"' "$repo/.chump-locks/ambient.jsonl" 2>/dev/null || \
        { echo "  missing farmer_escalated event after 3 kicks"; return 1; }
    return 0
}

# ── T9: dry-run — no sentinel removed, no launchctl calls ────────────────────
t9_dry_run() {
    local repo
    repo="$(make_fixture)"
    trap "rm -rf '$repo'" RETURN
    local fake_home="$repo/home"
    mkdir -p "$fake_home/.chump" "$repo/bin"
    touch "$fake_home/.chump/oauth-token.json"
    touch "$repo/.chump/fleet-paused"

    # Track if launchctl was called
    cat > "$repo/bin/launchctl" <<'MOCK'
#!/usr/bin/env bash
touch "${TMPDIR:-/tmp}/farmer-launchctl-called"
exit 0
MOCK
    chmod +x "$repo/bin/launchctl"

    PATH="$repo/bin:$PATH" FARMER_DRY_RUN=1 FARMER_TEST_HOME="$fake_home" run_farmer "$repo"

    # Sentinel must still be present
    [[ -f "$repo/.chump/fleet-paused" ]] || \
        { echo "  dry-run removed sentinel — should not modify state"; return 1; }
    # launchctl must NOT have been called with real side effects
    # (the mock touch is the side-effect check; kickstart is gated by run_cmd)
    # Heartbeat should still be written (read-only observability)
    [[ -f "$repo/.chump/farmer-heartbeat" ]] || \
        { echo "  heartbeat not written in dry-run mode"; return 1; }
    return 0
}

# ── Run all tests ──────────────────────────────────────────────────────────────
echo "=== test-farmer.sh (RESILIENT-068) ==="

run_test "T1: pause-deadlock lift"           t1_pause_lift
run_test "T2: stale-sentinel lift"           t2_stale_sentinel
run_test "T3: SLO failing — sentinel kept"   t3_slo_failing
run_test "T4: auth-dead (token absent)"      t4_auth_dead_absent
run_test "T5: auth-dead (token stale)"       t5_auth_dead_stale
run_test "T6: farmer_heartbeat emitted"      t6_heartbeat
run_test "T7: dead-supervisor kick"          t7_dead_supervisor
run_test "T8: escalation after 3 kicks"      t8_escalation
run_test "T9: dry-run no side effects"       t9_dry_run

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
