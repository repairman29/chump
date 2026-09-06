#!/usr/bin/env bash
# scripts/ci/test-nba-dispatch-beat.sh — EFFECTIVE-515
#
# Proves the auto-dispatch consumer's safety-critical behaviors:
#   1. allow-list boundary — an action-type NOT on the allow-list (e.g.
#      merge_pr) is ALWAYS deferred to the human, never acted on.
#   2. relapse-loop guard — a heal_organ target that relapses (fails again)
#      within CHUMP_NBA_HEAL_RELAPSE_SEC of a prior auto-heal is deferred,
#      not re-healed in a loop.
#   3. pause-guard — dispatch_worker_p0/p1 respects the fleet-paused
#      sentinel and defers instead of starting workers.
#   4. idempotency — the same top bet is not re-decided within
#      CHUMP_NBA_COOLDOWN_SEC (emits nba_dispatch_skipped, no duplicate
#      nba_dispatched).
#   5. stale-input guard — a producer board older than CHUMP_NBA_MAX_AGE_SEC
#      is refused (nba_dispatch_skipped reason=stale_input), never acted on.
#
# Without these guards this organ could auto-restart a genuinely broken
# service forever (relapse), override an operator's deliberate fleet pause,
# or act on a picture of the fleet that is no longer true.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BEAT="$REPO_ROOT/scripts/coord/nba-dispatch-beat.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-nba-dispatch-beat.sh (EFFECTIVE-515) ==="

# ── 0. Source contract ───────────────────────────────────────────────────────
[[ -f "$BEAT" ]] || fail "beat script missing: $BEAT"
[[ -x "$BEAT" ]] || fail "beat script not executable: $BEAT"
bash -n "$BEAT" || fail "beat script bash -n failed"
pass "script present, syntax clean"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/home/.chump"
AMBIENT="$TMP/ambient.jsonl"

# stub systemctl: is-failed reports "failed" for units listed in
# $FAILED_UNITS_FILE; reset-failed/restart/start/is-active/list-units all
# succeed trivially unless a unit is in FAILED_UNITS_FILE.
STUB="$TMP/systemctl-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CALL_LOG"
case "$1" in
    is-failed)
        unit="${@: -1}"
        if grep -qxF "$unit" "$FAILED_UNITS_FILE" 2>/dev/null; then
            echo "failed"; exit 1
        fi
        echo "active"; exit 0
        ;;
    reset-failed|restart|start|daemon-reload)
        exit 0
        ;;
    is-active)
        exit 0
        ;;
    list-units|list-unit-files)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$STUB"

FAILED_UNITS_FILE="$TMP/failed_units.txt"
CALL_LOG="$TMP/calls.log"
touch "$FAILED_UNITS_FILE"

# stub chump: records `gap reserve` invocations to $RESERVE_LOG and prints a
# fake gap ID, mirroring the mock pattern in test-bounced-pr-detector.sh.
# CHUMP_FAIL_RESERVE=1 makes it fail (no gap ID) to exercise the failure path.
CHUMP_STUB="$TMP/chump-stub"
cat > "$CHUMP_STUB" <<'CMOCK'
#!/usr/bin/env bash
if [[ "$1" == "gap" && "$2" == "reserve" ]]; then
    echo "$@" >> "$RESERVE_LOG"
    if [[ "${CHUMP_FAIL_RESERVE:-0}" == "1" ]]; then
        echo "reserve failed: similarity block" >&2
        exit 1
    fi
    echo "INFRA-$(date +%s)"
    exit 0
fi
exit 0
CMOCK
chmod +x "$CHUMP_STUB"
RESERVE_LOG="$TMP/reserve.log"

run_beat() {  # extra env assignments are read via caller-exported vars
    # CHUMP_AMBIENT_SCHEMA_CHECK=0: nba_dispatched / nba_deferred_to_human /
    # nba_dispatch_skipped are not yet registered in docs/ambient-schema.json's
    # legacy "event" enum, so ambient-emit.sh's schema gate rejects them
    # outright in strict mode (a real gap — filed separately). Bypass here so
    # this test proves the beat's decision logic, not the schema registration.
    : > "$CALL_LOG"
    HOME="$TMP/home" \
    CHUMP_NBA_OUT="$NBA_FILE" \
    CHUMP_NBA_DISPATCH_STATE="$STATE_FILE" \
    CHUMP_NBA_NEEDS_HUMAN_LOG="$TMP/needs-human.jsonl" \
    CHUMP_NBA_NEEDS_HUMAN_SNAP="$TMP/needs-human.json" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_AGENT_HARNESS="manual" \
    CHUMP_AMBIENT_SCHEMA_CHECK=0 \
    CHUMP_NBA_SYSTEMCTL_BIN="$STUB" \
    CALL_LOG="$CALL_LOG" \
    FAILED_UNITS_FILE="$FAILED_UNITS_FILE" \
    CHUMP_NBA_COOLDOWN_SEC="${COOLDOWN_SEC:-1800}" \
    CHUMP_NBA_HEAL_RELAPSE_SEC="${RELAPSE_SEC:-3600}" \
    CHUMP_NBA_MAX_AGE_SEC="${MAX_AGE_SEC:-3600}" \
    CHUMP_NBA_FLEET_PAUSE_FILE="${PAUSE_FILE:-$TMP/no-such-pause-file}" \
    CHUMP_BIN="$CHUMP_STUB" \
    RESERVE_LOG="$RESERVE_LOG" \
    CHUMP_FAIL_RESERVE="${CHUMP_FAIL_RESERVE:-0}" \
    bash "$BEAT" 2>&1
}

write_nba() {  # action target [generated_at_offset_sec]
    local action="$1" target="$2" age="${3:-0}"
    local gen_at
    gen_at="$(date -u -d "@$(( $(date -u +%s) - age ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -j -f "%s" "$(( $(date -u +%s) - age ))" +%Y-%m-%dT%H:%M:%SZ)"
    jq -n -c --arg gen "$gen_at" --arg action "$action" --arg target "$target" '
        { generated_at:$gen, count:1,
          recommendations:[{action:$action, target:$target, expected_value:1.0, p_success:0.9, why:"test", need_to_know:"test"}] }' \
        > "$NBA_FILE"
}

# ── 1. allow-list boundary: merge_pr (NOT on allow-list) always defers ───────
NBA_FILE="$TMP/nba-1.json"; STATE_FILE="$TMP/state-1.json"
write_nba "merge_pr" "1234"
: > "$AMBIENT"
out="$(run_beat)"
echo "$out" | grep -q "DEFER to human" || fail "merge_pr must defer to human; got: $out"
grep -q '"kind":"nba_deferred_to_human"' "$AMBIENT" \
    || fail "expected nba_deferred_to_human ambient event for merge_pr; got: $(cat "$AMBIENT")"
grep -q '"kind":"nba_dispatched"' "$AMBIENT" \
    && fail "merge_pr must NEVER be auto-dispatched (off-allow-list boundary breached)"
[[ -f "$TMP/needs-human.jsonl" ]] || fail "expected needs-human.jsonl to be written for a deferred action"
grep -q '"action":"merge_pr"' "$TMP/needs-human.jsonl" || fail "needs-human record missing action=merge_pr"
pass "1: allow-list boundary — merge_pr (off-list) is always deferred, never dispatched"

# ── 1b. allow-list boundary: wait_ci (ON allow-list) is a benign no-op dispatch
NBA_FILE="$TMP/nba-1b.json"; STATE_FILE="$TMP/state-1b.json"
write_nba "wait_ci" "some-pr"
: > "$AMBIENT"
out="$(run_beat)"
grep -q '"kind":"nba_dispatched"' "$AMBIENT" || fail "wait_ci should be auto-dispatched (allow-listed no-op); got: $(cat "$AMBIENT")"
pass "1b: allow-list boundary — wait_ci (on-list) is auto-dispatched as a no-op"

# ── 2. relapse-loop guard: heal_organ that FAILED again within the relapse
#       window after a prior auto-heal is deferred, NOT re-healed ───────────
NBA_FILE="$TMP/nba-2.json"; STATE_FILE="$TMP/state-2.json"
UNIT="chump-fake-organ.service"
echo "$UNIT" > "$FAILED_UNITS_FILE"
write_nba "heal_organ" "$UNIT"
: > "$AMBIENT"
out="$(run_beat)"
echo "$out" | grep -q "DISPATCHED" || fail "first heal of a failed organ should dispatch; got: $out"
grep -q '"kind":"nba_dispatched"' "$AMBIENT" || fail "expected nba_dispatched for first heal"
grep -q "reset-failed $UNIT" "$CALL_LOG" || fail "expected reset-failed call on first heal"

# simulate relapse: unit is failed again, cooldown for SIG is bypassed by
# advancing the "top bet" identity isn't needed (signature unchanged is fine
# here because heal_organ relapse detection keys off the heals map, not SIG
# cooldown) — but we must dodge the SIG cooldown so the second run is even
# evaluated. Use a fresh state with heals pre-seeded to simulate "healed
# recently" without re-running through the cooldown window.
RECENT_HEAL_TS="$(( $(date -u +%s) - 60 ))"
jq -n -c --arg sig "heal_organ|$UNIT" --argjson now 1 --arg unit "$UNIT" --argjson healed "$RECENT_HEAL_TS" '
    { updated_at:"1970-01-01T00:00:00Z", last_sig:"unrelated|nope", last_decision_ts:0,
      heals:{($unit):$healed} }' > "$STATE_FILE"
: > "$AMBIENT"
out="$(run_beat)"
echo "$out" | grep -q "RELAPSED" || fail "relapsed organ must be flagged as a relapse, not re-healed; got: $out"
echo "$out" | grep -q "DEFER to human" || fail "relapsed organ must defer to human; got: $out"
grep -q '"kind":"nba_deferred_to_human"' "$AMBIENT" \
    || fail "expected nba_deferred_to_human for relapsed organ; got: $(cat "$AMBIENT")"
grep -q "reset-failed $UNIT" "$CALL_LOG" \
    && fail "relapsed organ must NOT be reset-failed/restarted again (would loop); calls: $(cat "$CALL_LOG")"
pass "2: relapse-loop guard — organ that relapses after a recent auto-heal defers, is not re-healed"

# ── 3. pause-guard: dispatch_worker_p0 respects the fleet-paused sentinel ────
NBA_FILE="$TMP/nba-3.json"; STATE_FILE="$TMP/state-3.json"
PAUSE_FILE="$TMP/fleet-paused"
: > "$FAILED_UNITS_FILE"
write_nba "dispatch_worker_p0" "any"
touch "$PAUSE_FILE"
: > "$AMBIENT"
out="$(run_beat)"
echo "$out" | grep -q "PAUSED" || fail "paused fleet must be reported as the defer reason; got: $out"
grep -q '"kind":"nba_deferred_to_human"' "$AMBIENT" \
    || fail "expected nba_deferred_to_human when fleet is paused; got: $(cat "$AMBIENT")"
grep -qE "reset-failed|^start " "$CALL_LOG" \
    && fail "paused fleet must not start/revive any worker unit; calls: $(cat "$CALL_LOG")"
rm -f "$PAUSE_FILE"
pass "3: pause-guard — dispatch_worker_p0 defers when fleet-paused sentinel is present, never starts workers"

# ── 4. idempotency: same top bet within cooldown is skipped, not re-decided ──
NBA_FILE="$TMP/nba-4.json"; STATE_FILE="$TMP/state-4.json"
write_nba "wait_ci" "same-pr"
: > "$AMBIENT"
run_beat >/dev/null
first_dispatched_count="$(grep -c '"kind":"nba_dispatched"' "$AMBIENT")"
[[ "$first_dispatched_count" -eq 1 ]] || fail "expected exactly 1 nba_dispatched on first decision; got $first_dispatched_count"

out="$(run_beat)"
echo "$out" | grep -q "idempotent-skip" || fail "second identical-bet run within cooldown must idempotent-skip; got: $out"
grep -q '"kind":"nba_dispatch_skipped"' "$AMBIENT" \
    || fail "expected nba_dispatch_skipped on the cooldown-skipped cycle; got: $(cat "$AMBIENT")"
second_dispatched_count="$(grep -c '"kind":"nba_dispatched"' "$AMBIENT")"
[[ "$second_dispatched_count" -eq 1 ]] \
    || fail "cooldown-skipped cycle must NOT add another nba_dispatched; count=$second_dispatched_count"
pass "4: idempotency — identical top bet within cooldown is skipped, not re-decided or re-dispatched"

# ── 5. stale-input guard: producer board older than MAX_AGE_SEC is refused ──
NBA_FILE="$TMP/nba-5.json"; STATE_FILE="$TMP/state-5.json"
MAX_AGE_SEC=3600
write_nba "wait_ci" "stale-pr" 7200   # generated 2h ago, max age 1h
: > "$AMBIENT"
out="$(run_beat)"
echo "$out" | grep -q "stale" || fail "stale producer board must be reported as stale; got: $out"
grep -q '"kind":"nba_dispatch_skipped"' "$AMBIENT" \
    || fail "expected nba_dispatch_skipped for stale input; got: $(cat "$AMBIENT")"
grep -q '"reason":"stale_input"' "$AMBIENT" || fail "expected reason=stale_input in the skip event; got: $(cat "$AMBIENT")"
grep -q '"kind":"nba_dispatched"' "$AMBIENT" \
    && fail "stale producer board must NEVER be acted on; ambient: $(cat "$AMBIENT")"
pass "5: stale-input guard — a producer board older than CHUMP_NBA_MAX_AGE_SEC is refused, never acted on"
MAX_AGE_SEC=""

# ── 6. predicted_breakage (EFFECTIVE-510 slice): auto-files a P0 incident,
#       never touches anything ────────────────────────────────────────────
NBA_FILE="$TMP/nba-6.json"; STATE_FILE="$TMP/state-6.json"
write_nba "predicted_breakage" "worker-farm-3"
: > "$AMBIENT"; : > "$RESERVE_LOG"
out="$(run_beat)"
echo "$out" | grep -q "DISPATCHED" || fail "predicted_breakage should dispatch (escalate); got: $out"
grep -q '"kind":"nba_dispatched"' "$AMBIENT" \
    || fail "expected nba_dispatched for predicted_breakage; got: $(cat "$AMBIENT")"
grep -q "reserve.*--priority P0" "$RESERVE_LOG" \
    || fail "expected a P0 gap reserve call for predicted_breakage; reserve.log: $(cat "$RESERVE_LOG")"
grep -q "worker-farm-3" "$RESERVE_LOG" \
    || fail "expected the reserved P0 title to reference the predicted-breakage target; reserve.log: $(cat "$RESERVE_LOG")"
grep -qE "reset-failed|^start " "$CALL_LOG" \
    && fail "predicted_breakage must never touch systemd units — it only escalates; calls: $(cat "$CALL_LOG")"
pass "6a: predicted_breakage — auto-files a P0 incident (dispatch/escalate), never mutates any organ"

# ── 6b. predicted_breakage: a failed gap-reserve call defers to the human ────
NBA_FILE="$TMP/nba-6b.json"; STATE_FILE="$TMP/state-6b.json"
write_nba "predicted_breakage" "worker-farm-9"
: > "$AMBIENT"; : > "$RESERVE_LOG"
CHUMP_FAIL_RESERVE=1
out="$(run_beat)"
CHUMP_FAIL_RESERVE=0
grep -q '"kind":"nba_deferred_to_human"' "$AMBIENT" \
    || fail "expected nba_deferred_to_human when P0 reserve fails; got: $(cat "$AMBIENT")"
grep -q '"kind":"nba_dispatched"' "$AMBIENT" \
    && fail "a failed P0 reserve must not also be reported as dispatched; ambient: $(cat "$AMBIENT")"
pass "6b: predicted_breakage — a failed gap-reserve call defers to the human instead of silently swallowing it"

echo "ALL PASS"
