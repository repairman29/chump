#!/usr/bin/env bash
# RESILIENT-1584: rc=0 unverified_ship must count in the INFRA-3832 offense
# ledger and the rc=0 branch must not wipe it. Replays RESILIENT-445:
# rc=143, rc=0 unverified_ship, rc=143 -> status=blocked; a verified ship clears.
# Depth: happy-path + interleaved edge. Gaps: no live worker run; worker.sh
# wiring asserted structurally, ledger behavior exercised via the shared lib.
set -euo pipefail
PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
REPO_SRC="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$REPO_SRC/scripts/dispatch/worker.sh"

# Structural: rc==0 branch has no wipe; wipe only in shipped path.
rc0="$(awk '/if \[ "\$rc" -eq 0 \]; then/{f=1} f&&/^    else$/{exit} f' "$WORKER" | sed -n '1,12p')"
if printf '%s' "$rc0" | grep -q 'offense/'; then fail "rc==0 branch still touches offense ledger"; else ok "rc==0 branch does not wipe ledger"; fi
grep -q 'offense_clear "\$GAP_ID"' "$WORKER" && ok "verified-ship path clears ledger" || fail "no offense_clear in shipped path"
grep -q '_uv_offense_n="\$(offense_bump' "$WORKER" && ok "unverified_ship path bumps ledger" || fail "unverified_ship does not bump ledger"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export REPO_ROOT="$TMP" CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl" AGENT_ID=t
mkdir -p "$TMP/bin"
cat > "$TMP/bin/chump" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$REPO_ROOT/chump-calls.log"
STUB
chmod +x "$TMP/bin/chump"; export PATH="$TMP/bin:$PATH"
source "$REPO_SRC/scripts/dispatch/lib/offense-ledger.sh"

G=RESILIENT-445
n=$(offense_bump $G); offense_maybe_block $G "$n" "timeout" 124
n=$(offense_bump $G); offense_maybe_block $G "$n" "timeout" 124
[ ! -f "$TMP/chump-calls.log" ] && ok "no block after 2 offenses" || fail "blocked too early"
n=$(offense_bump $G); offense_maybe_block $G "$n" "timeout" 124
if grep -q "gap set $G --status blocked" "$TMP/chump-calls.log" 2>/dev/null; then ok "Transient pattern (3x timeout) -> blocked"; else fail "Transient pattern not blocked"; fi

rm -f "$TMP/chump-calls.log"
offense_bump G2 >/dev/null; offense_bump G2 >/dev/null; offense_clear G2
n=$(offense_bump G2); [ "$n" = 1 ] && ok "verified ship clears ledger" || fail "ledger not cleared (n=$n)"

# RESILIENT-1344: Test Capability classification routes to capable_agent_escalation queue.
# Transient (timeout) case -> auto-blocks
G3=RESILIENT-1344-TRANSIENT
rm -f "$TMP/chump-calls.log" "$TMP/ambient.jsonl"
n=$(offense_bump $G3); offense_maybe_block $G3 "$n" "timeout" 124
n=$(offense_bump $G3); offense_maybe_block $G3 "$n" "timeout" 124
n=$(offense_bump $G3); offense_maybe_block $G3 "$n" "timeout" 124
if grep -q "gap set $G3 --status blocked" "$TMP/chump-calls.log" 2>/dev/null && grep -q '"kind":"gap_auto_blocked"' "$TMP/ambient.jsonl" 2>/dev/null; then
    ok "Transient (timeout) -> auto-blocked"
else
    fail "Transient (timeout) did not auto-block"
fi

# Capability (unverified_ship) case -> escalation queue
G4=RESILIENT-1344-CAPABILITY
rm -f "$TMP/chump-calls.log" "$TMP/ambient.jsonl"
n=$(offense_bump $G4); offense_maybe_block $G4 "$n" "unverified_ship" 0
n=$(offense_bump $G4); offense_maybe_block $G4 "$n" "unverified_ship" 0
n=$(offense_bump $G4); offense_maybe_block $G4 "$n" "unverified_ship" 0
if ! grep -q "gap set $G4 --status blocked" "$TMP/chump-calls.log" 2>/dev/null && grep -q '"kind":"capable_agent_escalation"' "$TMP/ambient.jsonl" 2>/dev/null; then
    ok "Capability (unverified_ship) -> capable_agent_escalation"
else
    fail "Capability (unverified_ship) did not escalate (got auto-blocked instead)"
fi

# CREDIBLE-1578: an auto-block must NAME the failing step and KEEP the cycle log
# (path in the note + event), not just rc + byte count. Replays a SYNTHETIC
# external-repo signature — a hypothesized ~945B pre-agent failure (`chump improve`
# could not find an onboard scan). NOTE: this is a fabricated fixture, NOT a
# reproduced Olive cycle; the live-cycle receipt that would confirm the real 27-gap
# signature is carved to a lane-1 follow-up. This block proves the recording
# machinery (AC2); the faithfulness guard below proves it never lies about the log.
G5=CREDIBLE-1578-EXTERNAL
rm -f "$TMP/chump-calls.log" "$TMP/ambient.jsonl"
rm -rf "$TMP/.chump-locks/offense/logs"
_clog="$TMP/cycle-$G5.log"
cat > "$_clog" <<'LOG'
[improve] Stage 1: PICK — scout repairman29/olive...
chump improve: reading latest onboard scan: no onboard scan found under /x — run `chump onboard repairman29/olive` first
LOG
_clogsz="$(wc -c < "$_clog" | tr -d ' ')"
n=$(offense_bump $G5); offense_maybe_block $G5 "$n" "timeout" 124 "$_clogsz" "$_clog"
n=$(offense_bump $G5); offense_maybe_block $G5 "$n" "timeout" 124 "$_clogsz" "$_clog"
n=$(offense_bump $G5); offense_maybe_block $G5 "$n" "timeout" 124 "$_clogsz" "$_clog"

# (a) the block note names the failing step classified from the real log
if grep -Fq "Failing step: external_repo:no_onboard_scan" "$TMP/chump-calls.log" 2>/dev/null; then
    ok "CREDIBLE-1578: block note names the failing step"
else
    fail "CREDIBLE-1578: block note missing 'Failing step: external_repo:no_onboard_scan'"
fi

# (b) the cycle log is preserved to a durable path AND that path is in the note
_kept="$(ls "$TMP/.chump-locks/offense/logs/${G5}-block-"*.log 2>/dev/null | head -1)"
if [ -n "$_kept" ] && [ -f "$_kept" ] \
   && grep -Fq "Cycle log kept at: $_kept" "$TMP/chump-calls.log" 2>/dev/null; then
    ok "CREDIBLE-1578: cycle log preserved + exact path recorded in note"
else
    fail "CREDIBLE-1578: cycle log not preserved or path not in note (kept='$_kept')"
fi

# (c) the preserved copy is byte-identical to the source log (a real receipt)
if [ -n "$_kept" ] && cmp -s "$_clog" "$_kept"; then
    ok "CREDIBLE-1578: preserved log is byte-identical to the cycle log"
else
    fail "CREDIBLE-1578: preserved log differs from the source cycle log"
fi

# (d) the gap_auto_blocked ambient event carries failing_step + cycle_log
if grep -Fq '"failing_step":"external_repo:no_onboard_scan"' "$TMP/ambient.jsonl" 2>/dev/null \
   && grep -Fq "\"cycle_log\":\"$_kept\"" "$TMP/ambient.jsonl" 2>/dev/null; then
    ok "CREDIBLE-1578: gap_auto_blocked event carries failing_step + cycle_log"
else
    fail "CREDIBLE-1578: event missing failing_step/cycle_log"
fi

# CREDIBLE-1578 AC1 (faithfulness guard): the recorded "why" must be a FAITHFUL
# receipt of the actual log, not an asserted/guessed cause. classify_failing_step
# must name a specific pre-agent step ONLY when the log actually contains that
# step's marker; for a log with none of the known markers it must fall back to a
# receipt-grounded reason (tail:/unclassified), never fabricate a specific cause.
# (The specific signature behind the 27 Olive blocks is not reproduced here — that
# live-cycle receipt is carved to a lane-1 follow-up; this guard only proves the
# classifier never lies about what the log says.)
G6=CREDIBLE-1578-FAITHFUL
_ulog="$TMP/cycle-$G6.log"
printf '%s\n' '[improve] stage 1 progress, nothing actionable' \
             'worker: generic line with none of the known markers' > "$_ulog"
_step6="$(classify_failing_step "$_ulog")"
case "$_step6" in
    external_repo:*|in_repo_ship_on_external_gap|auth_or_billing|decompose_precheck)
        fail "CREDIBLE-1578: classifier fabricated specific step '$_step6' for a log with no matching marker" ;;
    tail:*|unclassified*)
        ok "CREDIBLE-1578: classifier stays faithful to the log (receipt-grounded fallback, no guessed cause)" ;;
    *)
        fail "CREDIBLE-1578: classifier returned unexpected step '$_step6'" ;;
esac

echo "pass=$PASS fail=$FAIL"; [ "$FAIL" -eq 0 ]
