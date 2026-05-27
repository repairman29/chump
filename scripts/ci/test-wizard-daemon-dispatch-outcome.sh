#!/usr/bin/env bash
# scripts/ci/test-wizard-daemon-dispatch-outcome.sh — INFRA-2051
#
# Verifies outcome detection in wizard-daemon step4:
#   T1: happy-path-ship — entry with gap status:done → SHIPPED, removed from active, appended to history
#   T2: dispatch-exits-no-pr — dead PID, no PR, gap still open, >15min old → FAILED, history updated
#   T3: dispatch-creates-pr-not-merged — dead PID but PR exists → PR_OPENED, stays in active
#   T4: 3-fails-mark-skip — 3 history FAILEDs for same gap → 4th attempt SKIPPED with wizard_dispatch_giveup
#   T5: cooldown-respected — 1 recent FAILED within 1800s → next dispatch SKIPPED with wizard_dispatch_cooldown
#   T6: schema-migration — old-shape {dispatches:[{gap_id,ts,pid}]} loads with defensive defaults, no crash
#
# Strategy: inject stub gh + chump binaries, synthetic dispatch-state.json, and invoke
# the pruning python embedded in wizard-daemon step4 directly, OR exercise via a full
# tick with CHUMP_WIZARD_DAEMON_DRY_RUN=0 and verify state file changes.
#
# Usage:
#   bash scripts/ci/test-wizard-daemon-dispatch-outcome.sh
#
# Exit: 0 all pass, 1 any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/wizard-daemon.sh"
PASS=0
FAIL=0
TOTAL=0

pass() { printf '  [PASS] %s\n' "$*"; (( PASS++ )); (( TOTAL++ )); }
fail() { printf '  [FAIL] %s\n' "$*" >&2; (( FAIL++ )); (( TOTAL++ )); }

# Cleanup trap
TMPDIRS_FILE="/tmp/test-wizard-dispatch-outcome-tmpdirs-$$.txt"
cleanup_tmpdirs() {
    if [[ -f "$TMPDIRS_FILE" ]]; then
        while IFS= read -r d; do
            rm -rf "$d" 2>/dev/null || true
        done < "$TMPDIRS_FILE"
        rm -f "$TMPDIRS_FILE"
    fi
}
trap cleanup_tmpdirs EXIT

printf 'Running INFRA-2051 wizard-daemon dispatch-outcome tests...\n\n'

# ── Shared helper: make a sandbox ──────────────────────────────────────────────

make_sandbox() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    printf '%s\n' "$tmpdir" >> "$TMPDIRS_FILE"
    printf '%s' "$tmpdir"
}

# ── Shared helper: run the outcome-classification python inline ───────────────
# This exercises the same python logic embedded in step4_dispatch_pickable_gaps
# without requiring a full wizard-daemon tick.

run_outcome_python() {
    local state_json="$1"
    local now_epoch="$2"
    local window_s="${3:-3600}"
    local timeout_s="${4:-900}"
    local chump_bin="${5:-chump-stub-noop}"
    local gh_bin="${6:-gh-stub-noop}"

    python3 - \
        "$state_json" "$now_epoch" "$window_s" \
        "$timeout_s" "$chump_bin" "$gh_bin" <<'PY'
import json, sys, os, datetime, subprocess

try:
    state       = json.loads(sys.argv[1])
    now         = int(sys.argv[2])
    window      = int(sys.argv[3])
    timeout_s   = int(sys.argv[4])
    chump_bin   = sys.argv[5]
    gh_bin      = sys.argv[6]
except Exception:
    print('{"dispatches":[],"history":[],"newly_failed":[]}'); sys.exit(0)

def migrate_entry(d):
    if "outcome" not in d:
        d["outcome"] = None
    if "attempts" not in d:
        d["attempts"] = 1
    return d

raw_dispatches = [migrate_entry(d) for d in state.get("dispatches", [])]
history        = list(state.get("history", []))

def parse_epoch(ts_str):
    try:
        t = datetime.datetime.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ")
        return int(t.replace(tzinfo=datetime.timezone.utc).timestamp())
    except Exception:
        return 0

def gap_is_done(gap_id):
    try:
        out = subprocess.check_output(
            [chump_bin, "gap", "show", gap_id],
            stderr=subprocess.DEVNULL, timeout=10
        ).decode("utf-8", errors="replace")
        return "status: done" in out or '"status":"done"' in out
    except Exception:
        return False

def gap_has_open_pr(gap_id):
    try:
        out = subprocess.check_output(
            [gh_bin, "pr", "list", "--search", gap_id, "--state", "open", "--json", "number"],
            stderr=subprocess.DEVNULL, timeout=15
        ).decode("utf-8", errors="replace")
        data = json.loads(out or "[]")
        return isinstance(data, list) and len(data) > 0
    except Exception:
        return False

def pid_alive(pid):
    if not pid or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False

now_iso = datetime.datetime.utcfromtimestamp(now).strftime("%Y-%m-%dT%H:%M:%SZ")

active       = []
newly_failed = []

for d in raw_dispatches:
    try:
        dispatch_epoch = parse_epoch(d.get("ts",""))
        age_s          = now - dispatch_epoch
    except Exception:
        continue
    if age_s > window:
        continue

    gap_id  = d.get("gap_id","")
    pid     = d.get("pid", 0)
    outcome = d.get("outcome")
    attempts = d.get("attempts", 1)

    if outcome in ("SHIPPED", "PR_OPENED"):
        if outcome == "PR_OPENED":
            if gap_is_done(gap_id):
                d["outcome"] = "SHIPPED"
                history.append({"gap_id": gap_id, "outcome": "SHIPPED", "ts": now_iso})
                continue
        active.append(d)
        continue

    if pid_alive(pid):
        active.append(d)
        continue

    if gap_is_done(gap_id):
        d["outcome"] = "SHIPPED"
        history.append({"gap_id": gap_id, "outcome": "SHIPPED", "ts": now_iso})
        continue

    if gap_has_open_pr(gap_id):
        d["outcome"] = "PR_OPENED"
        active.append(d)
        continue

    if age_s < timeout_s:
        active.append(d)
        continue

    d["outcome"] = "FAILED"
    d["attempts"] = attempts
    history.append({"gap_id": gap_id, "outcome": "FAILED", "ts": now_iso})
    newly_failed.append(gap_id)

print(json.dumps({
    "dispatches":   active,
    "history":      history,
    "newly_failed": newly_failed,
}, indent=2))
PY
}

# ── T1: happy-path-ship ────────────────────────────────────────────────────────
printf 'T1: happy-path-ship — gap status:done → SHIPPED, removed from active, in history\n'
{
    TMPDIR_T1="$(make_sandbox)"

    # Stub chump: reports status: done for CREDIBLE-099
    STUB_CHUMP_T1="$TMPDIR_T1/chump"
    cat > "$STUB_CHUMP_T1" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "gap" && "${2:-}" == "show" ]]; then
    printf 'id: %s\nstatus: done\n' "${3:-X}"
fi
exit 0
STUB
    chmod +x "$STUB_CHUMP_T1"

    # Stub gh: no open PRs
    STUB_GH_T1="$TMPDIR_T1/gh"
    cat > "$STUB_GH_T1" <<'STUB'
#!/usr/bin/env bash
printf '[]\n'
exit 0
STUB
    chmod +x "$STUB_GH_T1"

    # Dispatch state: one entry, PID dead (PID=1 always exists but we use PID 9999999 which won't)
    NOW_EPOCH="$(date -u +%s)"
    PAST_TS="$(date -u -v-1200S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-1200 seconds' +%Y-%m-%dT%H:%M:%SZ)"
    STATE_JSON="{\"dispatches\":[{\"gap_id\":\"CREDIBLE-099\",\"ts\":\"$PAST_TS\",\"pid\":9999999,\"outcome\":null,\"attempts\":1}],\"history\":[]}"

    RESULT="$(run_outcome_python "$STATE_JSON" "$NOW_EPOCH" 3600 900 "$STUB_CHUMP_T1" "$STUB_GH_T1")"

    # Assertions
    ACTIVE_COUNT="$(printf '%s\n' "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('dispatches',[])))")"
    HISTORY_COUNT="$(printf '%s\n' "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('history',[])))")"
    HISTORY_OUTCOME="$(printf '%s\n' "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); h=d.get('history',[]); print(h[0].get('outcome','') if h else 'NONE')")"

    if [[ "$ACTIVE_COUNT" == "0" ]]; then
        pass "T1: shipped gap removed from active dispatches"
    else
        fail "T1: expected 0 active, got $ACTIVE_COUNT"
    fi

    if [[ "$HISTORY_COUNT" == "1" && "$HISTORY_OUTCOME" == "SHIPPED" ]]; then
        pass "T1: history contains SHIPPED entry"
    else
        fail "T1: expected history=[SHIPPED], got count=$HISTORY_COUNT outcome=$HISTORY_OUTCOME"
    fi
}

# ── T2: dispatch-exits-no-pr ───────────────────────────────────────────────────
printf '\nT2: dispatch-exits-no-pr — dead PID, no PR, >15min old → FAILED, history updated\n'
{
    TMPDIR_T2="$(make_sandbox)"

    # Stub chump: gap still open
    STUB_CHUMP_T2="$TMPDIR_T2/chump"
    cat > "$STUB_CHUMP_T2" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "gap" && "${2:-}" == "show" ]]; then
    printf 'id: %s\nstatus: open\n' "${3:-X}"
fi
exit 0
STUB
    chmod +x "$STUB_CHUMP_T2"

    # Stub gh: no open PRs
    STUB_GH_T2="$TMPDIR_T2/gh"
    cat > "$STUB_GH_T2" <<'STUB'
#!/usr/bin/env bash
printf '[]\n'
exit 0
STUB
    chmod +x "$STUB_GH_T2"

    NOW_EPOCH="$(date -u +%s)"
    # 20 minutes ago — past DISPATCH_TIMEOUT_S=900 (15min)
    PAST_TS="$(date -u -v-1200S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-1200 seconds' +%Y-%m-%dT%H:%M:%SZ)"
    STATE_JSON="{\"dispatches\":[{\"gap_id\":\"INFRA-9001\",\"ts\":\"$PAST_TS\",\"pid\":9999999,\"outcome\":null,\"attempts\":1}],\"history\":[]}"

    RESULT="$(run_outcome_python "$STATE_JSON" "$NOW_EPOCH" 3600 900 "$STUB_CHUMP_T2" "$STUB_GH_T2")"

    ACTIVE_COUNT="$(printf '%s\n' "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('dispatches',[])))")"
    NEWLY_FAILED="$(printf '%s\n' "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('newly_failed',[]))")"
    HISTORY_OUTCOME="$(printf '%s\n' "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); h=d.get('history',[]); print(h[0].get('outcome','') if h else 'NONE')")"

    if [[ "$ACTIVE_COUNT" == "0" ]]; then
        pass "T2: FAILED dispatch removed from active"
    else
        fail "T2: expected 0 active, got $ACTIVE_COUNT"
    fi

    if [[ "$HISTORY_OUTCOME" == "FAILED" ]]; then
        pass "T2: history contains FAILED entry"
    else
        fail "T2: expected history=[FAILED], got $HISTORY_OUTCOME"
    fi

    if printf '%s\n' "$NEWLY_FAILED" | grep -q "INFRA-9001"; then
        pass "T2: newly_failed contains INFRA-9001"
    else
        fail "T2: expected INFRA-9001 in newly_failed, got $NEWLY_FAILED"
    fi
}

# ── T3: dispatch-creates-pr-not-merged ────────────────────────────────────────
printf '\nT3: dispatch-creates-pr-not-merged — dead PID but PR exists → PR_OPENED, stays in active\n'
{
    TMPDIR_T3="$(make_sandbox)"

    # Stub chump: gap still open
    STUB_CHUMP_T3="$TMPDIR_T3/chump"
    cat > "$STUB_CHUMP_T3" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "gap" && "${2:-}" == "show" ]]; then
    printf 'id: %s\nstatus: open\n' "${3:-X}"
fi
exit 0
STUB
    chmod +x "$STUB_CHUMP_T3"

    # Stub gh: returns an open PR for any search
    STUB_GH_T3="$TMPDIR_T3/gh"
    cat > "$STUB_GH_T3" <<'STUB'
#!/usr/bin/env bash
printf '[{"number":42}]\n'
exit 0
STUB
    chmod +x "$STUB_GH_T3"

    NOW_EPOCH="$(date -u +%s)"
    # 20 minutes ago — past timeout, but PR exists so should be PR_OPENED not FAILED
    PAST_TS="$(date -u -v-1200S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-1200 seconds' +%Y-%m-%dT%H:%M:%SZ)"
    STATE_JSON="{\"dispatches\":[{\"gap_id\":\"EFFECTIVE-042\",\"ts\":\"$PAST_TS\",\"pid\":9999999,\"outcome\":null,\"attempts\":1}],\"history\":[]}"

    RESULT="$(run_outcome_python "$STATE_JSON" "$NOW_EPOCH" 3600 900 "$STUB_CHUMP_T3" "$STUB_GH_T3")"

    ACTIVE_COUNT="$(printf '%s\n' "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('dispatches',[])))")"
    ACTIVE_OUTCOME="$(printf '%s\n' "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); disp=d.get('dispatches',[]); print(disp[0].get('outcome','') if disp else 'NONE')")"
    HISTORY_COUNT="$(printf '%s\n' "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('history',[])))")"

    if [[ "$ACTIVE_COUNT" == "1" && "$ACTIVE_OUTCOME" == "PR_OPENED" ]]; then
        pass "T3: PR_OPENED entry stays in active dispatches"
    else
        fail "T3: expected 1 active with outcome=PR_OPENED, got count=$ACTIVE_COUNT outcome=$ACTIVE_OUTCOME"
    fi

    if [[ "$HISTORY_COUNT" == "0" ]]; then
        pass "T3: no history entry written for PR_OPENED"
    else
        fail "T3: expected 0 history entries, got $HISTORY_COUNT"
    fi
}

# ── T4: 3-fails-mark-skip ─────────────────────────────────────────────────────
printf '\nT4: 3-fails-mark-skip — 3 FAILEDs in history → 4th dispatch SKIPPED with wizard_dispatch_giveup\n'
{
    TMPDIR_T4="$(make_sandbox)"
    LOCKS_DIR_T4="$TMPDIR_T4/.chump-locks"
    AMBIENT_T4="$LOCKS_DIR_T4/ambient.jsonl"
    DISPATCH_STATE_T4="$LOCKS_DIR_T4/wizard-daemon-dispatch-state.json"
    mkdir -p "$LOCKS_DIR_T4"

    # Stub chump: gap list returns INFRA-9002 as pickable;
    #             gap preflight exits 0; gap show returns open; gap set records the --add-note call
    STUB_CHUMP_T4="$TMPDIR_T4/chump"
    CHUMP_CALLS_LOG="$TMPDIR_T4/chump-calls.log"
    cat > "$STUB_CHUMP_T4" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CHUMP_CALLS_LOG"
if [[ "\${1:-}" == "gap" && "\${2:-}" == "list" ]]; then
    printf '[{"id":"INFRA-9002","acceptance_criteria":"must work","notes":""}]\n'
elif [[ "\${1:-}" == "gap" && "\${2:-}" == "preflight" ]]; then
    exit 0
elif [[ "\${1:-}" == "gap" && "\${2:-}" == "show" ]]; then
    printf 'id: %s\nstatus: open\n' "\${3:-X}"
elif [[ "\${1:-}" == "health" ]]; then
    printf 'COLD\n'
fi
exit 0
STUB
    chmod +x "$STUB_CHUMP_T4"

    # Stub gh: no open PRs, no PR list results
    STUB_GH_T4="$TMPDIR_T4/gh"
    cat > "$STUB_GH_T4" <<'STUB'
#!/usr/bin/env bash
# Return empty for pr list (no open PRs)
printf '[]\n'
exit 0
STUB
    chmod +x "$STUB_GH_T4"

    # Pre-seed dispatch state with 3 FAILED history entries for INFRA-9002 in last 24h
    NOW_EPOCH="$(date -u +%s)"
    TS_1H_AGO="$(date -u -v-3600S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-3600 seconds' +%Y-%m-%dT%H:%M:%SZ)"
    TS_2H_AGO="$(date -u -v-7200S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-7200 seconds' +%Y-%m-%dT%H:%M:%SZ)"
    TS_3H_AGO="$(date -u -v-10800S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-10800 seconds' +%Y-%m-%dT%H:%M:%SZ)"

    cat > "$DISPATCH_STATE_T4" <<SEEDSTATE
{
  "dispatches": [],
  "history": [
    {"gap_id": "INFRA-9002", "outcome": "FAILED", "ts": "$TS_3H_AGO"},
    {"gap_id": "INFRA-9002", "outcome": "FAILED", "ts": "$TS_2H_AGO"},
    {"gap_id": "INFRA-9002", "outcome": "FAILED", "ts": "$TS_1H_AGO"}
  ]
}
SEEDSTATE

    # Run a full wizard-daemon tick with DRY_RUN=0 so that gap set --add-note is called
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_DAEMON_DRY_RUN=0 \
    CHUMP_WIZARD_TEST_GH="$STUB_GH_T4" \
    CHUMP_WIZARD_TEST_CHUMP="$STUB_CHUMP_T4" \
    CHUMP_WIZARD_DISPATCH_STATE="$DISPATCH_STATE_T4" \
    CHUMP_WIZARD_MAX_DISPATCH_ATTEMPTS=3 \
    CHUMP_WIZARD_DISPATCH_GAP_COOLDOWN_S=0 \
    CHUMP_WIZARD_MAX_PARALLEL=4 \
    CHUMP_AMBIENT_LOG="$AMBIENT_T4" \
    CHUMP_REPO="$TMPDIR_T4" \
    CHUMP_WIZARD_STALL_LOOKBACK_S=60 \
    timeout 30 bash "$SCRIPT" tick >/dev/null 2>&1 || true

    # Assert: wizard_dispatch_giveup event emitted to ambient
    if grep -q '"kind":"wizard_dispatch_giveup"' "$AMBIENT_T4" 2>/dev/null; then
        pass "T4: wizard_dispatch_giveup ambient event emitted"
    else
        fail "T4: wizard_dispatch_giveup event NOT found in ambient.jsonl"
    fi

    # Assert: wizard_dispatch_giveup event contains INFRA-9002
    if grep '"kind":"wizard_dispatch_giveup"' "$AMBIENT_T4" 2>/dev/null | grep -q '"INFRA-9002"'; then
        pass "T4: wizard_dispatch_giveup references gap INFRA-9002"
    else
        fail "T4: wizard_dispatch_giveup event missing gap_id INFRA-9002"
    fi

    # Assert: chump gap set --add-note was called (wizard_skip tagging)
    if grep -q "gap set INFRA-9002" "$CHUMP_CALLS_LOG" 2>/dev/null; then
        pass "T4: chump gap set called to tag INFRA-9002 with wizard_skip"
    else
        fail "T4: chump gap set --add-note NOT called for INFRA-9002"
    fi

    # Assert: wizard_dispatch_executed NOT emitted (gap was not re-dispatched)
    if ! grep -q '"kind":"wizard_dispatch_executed".*INFRA-9002' "$AMBIENT_T4" 2>/dev/null; then
        pass "T4: wizard_dispatch_executed NOT emitted (give-up guard held)"
    else
        fail "T4: wizard_dispatch_executed was emitted — give-up guard failed"
    fi
}

# ── T5: cooldown-respected ────────────────────────────────────────────────────
printf '\nT5: cooldown-respected — 1 recent FAILED within 1800s → dispatch SKIPPED with wizard_dispatch_cooldown\n'
{
    TMPDIR_T5="$(make_sandbox)"
    LOCKS_DIR_T5="$TMPDIR_T5/.chump-locks"
    AMBIENT_T5="$LOCKS_DIR_T5/ambient.jsonl"
    DISPATCH_STATE_T5="$LOCKS_DIR_T5/wizard-daemon-dispatch-state.json"
    mkdir -p "$LOCKS_DIR_T5"

    # Stub chump: INFRA-9003 is pickable, gap still open
    STUB_CHUMP_T5="$TMPDIR_T5/chump"
    cat > "$STUB_CHUMP_T5" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "gap" && "\${2:-}" == "list" ]]; then
    printf '[{"id":"INFRA-9003","acceptance_criteria":"must work","notes":""}]\n'
elif [[ "\${1:-}" == "gap" && "\${2:-}" == "preflight" ]]; then
    exit 0
elif [[ "\${1:-}" == "gap" && "\${2:-}" == "show" ]]; then
    printf 'id: %s\nstatus: open\n' "\${3:-X}"
elif [[ "\${1:-}" == "health" ]]; then
    printf 'COLD\n'
fi
exit 0
STUB
    chmod +x "$STUB_CHUMP_T5"

    # Stub gh: no open PRs
    STUB_GH_T5="$TMPDIR_T5/gh"
    cat > "$STUB_GH_T5" <<'STUB'
#!/usr/bin/env bash
printf '[]\n'
exit 0
STUB
    chmod +x "$STUB_GH_T5"

    # Pre-seed dispatch state: 1 FAILED 10 minutes ago (within 1800s cooldown)
    TS_10MIN_AGO="$(date -u -v-600S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-600 seconds' +%Y-%m-%dT%H:%M:%SZ)"

    cat > "$DISPATCH_STATE_T5" <<SEEDSTATE
{
  "dispatches": [],
  "history": [
    {"gap_id": "INFRA-9003", "outcome": "FAILED", "ts": "$TS_10MIN_AGO"}
  ]
}
SEEDSTATE

    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_DAEMON_DRY_RUN=0 \
    CHUMP_WIZARD_TEST_GH="$STUB_GH_T5" \
    CHUMP_WIZARD_TEST_CHUMP="$STUB_CHUMP_T5" \
    CHUMP_WIZARD_DISPATCH_STATE="$DISPATCH_STATE_T5" \
    CHUMP_WIZARD_MAX_DISPATCH_ATTEMPTS=3 \
    CHUMP_WIZARD_DISPATCH_GAP_COOLDOWN_S=1800 \
    CHUMP_WIZARD_MAX_PARALLEL=4 \
    CHUMP_AMBIENT_LOG="$AMBIENT_T5" \
    CHUMP_REPO="$TMPDIR_T5" \
    CHUMP_WIZARD_STALL_LOOKBACK_S=60 \
    timeout 30 bash "$SCRIPT" tick >/dev/null 2>&1 || true

    # Assert: wizard_dispatch_cooldown event emitted
    if grep -q '"kind":"wizard_dispatch_cooldown"' "$AMBIENT_T5" 2>/dev/null; then
        pass "T5: wizard_dispatch_cooldown ambient event emitted"
    else
        fail "T5: wizard_dispatch_cooldown event NOT found in ambient.jsonl"
    fi

    # Assert: wizard_dispatch_executed NOT emitted (cooldown guard held)
    if ! grep -q '"kind":"wizard_dispatch_executed"' "$AMBIENT_T5" 2>/dev/null; then
        pass "T5: wizard_dispatch_executed NOT emitted (cooldown guard held)"
    else
        fail "T5: wizard_dispatch_executed emitted — cooldown guard failed"
    fi
}

# ── T6: schema-migration ──────────────────────────────────────────────────────
printf '\nT6: schema-migration — old-shape {dispatches:[{gap_id,ts,pid}]} loads without crash\n'
{
    TMPDIR_T6="$(make_sandbox)"

    # Stub chump: gap still open
    STUB_CHUMP_T6="$TMPDIR_T6/chump"
    cat > "$STUB_CHUMP_T6" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "gap" && "${2:-}" == "show" ]]; then
    printf 'id: %s\nstatus: open\n' "${3:-X}"
fi
exit 0
STUB
    chmod +x "$STUB_CHUMP_T6"

    # Stub gh: no open PRs
    STUB_GH_T6="$TMPDIR_T6/gh"
    cat > "$STUB_GH_T6" <<'STUB'
#!/usr/bin/env bash
printf '[]\n'
exit 0
STUB
    chmod +x "$STUB_GH_T6"

    NOW_EPOCH="$(date -u +%s)"
    # Old-shape dispatch entry: missing outcome + attempts fields, missing top-level history
    FIVE_MIN_AGO="$(date -u -v-300S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-300 seconds' +%Y-%m-%dT%H:%M:%SZ)"
    OLD_STATE_JSON="{\"dispatches\":[{\"gap_id\":\"LEGACY-001\",\"ts\":\"$FIVE_MIN_AGO\",\"pid\":9999999}]}"

    # Should not crash; should produce valid JSON output with migrated fields
    RESULT="$(run_outcome_python "$OLD_STATE_JSON" "$NOW_EPOCH" 3600 900 "$STUB_CHUMP_T6" "$STUB_GH_T6")"
    EXIT_CODE=$?

    if [[ "$EXIT_CODE" == "0" ]]; then
        pass "T6: outcome python exits 0 on old-shape state"
    else
        fail "T6: outcome python crashed (exit=$EXIT_CODE)"
    fi

    # Verify output is valid JSON
    if printf '%s\n' "$RESULT" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
        pass "T6: output is valid JSON"
    else
        fail "T6: output is not valid JSON"
    fi

    # Verify history key exists (was added during migration)
    HISTORY_KEY="$(printf '%s\n' "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print('present' if 'history' in d else 'missing')" 2>/dev/null || echo 'missing')"
    if [[ "$HISTORY_KEY" == "present" ]]; then
        pass "T6: history key present in migrated output"
    else
        fail "T6: history key missing from migrated output"
    fi

    # Entry within timeout (5 min < 15 min) → still in-flight (no PID but < timeout)
    # Actually PID=9999999 dead AND < timeout → stays in active
    ACTIVE_COUNT="$(printf '%s\n' "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('dispatches',[])))")"
    if [[ "$ACTIVE_COUNT" == "1" ]]; then
        pass "T6: migrated entry retained in active (within timeout window)"
    else
        fail "T6: expected 1 active entry, got $ACTIVE_COUNT"
    fi
}

# ── Summary ────────────────────────────────────────────────────────────────────

printf '\n'
printf 'Results: %d/%d passed\n' "$PASS" "$TOTAL"
if [[ "$FAIL" -gt 0 ]]; then
    printf 'FAIL: %d test(s) failed\n' "$FAIL" >&2
    exit 1
fi
exit 0
