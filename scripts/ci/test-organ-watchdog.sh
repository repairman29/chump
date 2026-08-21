#!/usr/bin/env bash
# scripts/ci/test-organ-watchdog.sh — INFRA-3595
#
# Proves the organ-watchdog self-heals a failed chump-* organ with no human
# step (gap AC 7): a stubbed `systemctl` reports chump-sla-scorecard.service
# as failed; the watchdog must call `reset-failed` then `restart` on it and
# emit organ_self_healed. A second stub reports a healthy fleet — the
# watchdog must heal nothing and still emit the organ_watchdog_tick heartbeat.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WATCHDOG="$REPO_ROOT/scripts/ops/organ-watchdog.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-organ-watchdog.sh (INFRA-3595) ==="

# ── 1. Source contract ───────────────────────────────────────────────────────
[[ -f "$WATCHDOG" ]] || fail "watchdog script missing: $WATCHDOG"
[[ -x "$WATCHDOG" ]] || fail "watchdog script not executable: $WATCHDOG"
bash -n "$WATCHDOG" || fail "watchdog bash -n failed"
for unit in service timer; do
    f="$REPO_ROOT/scripts/dispatch/chump-organ-watchdog.$unit"
    [[ -f "$f" ]] || fail "missing $f"
done
pass "script + unit files present, syntax clean"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Harmless no-op deploy-script stub for tests that aren't exercising the
# INFRA-3598 deploy wiring itself — decouples this test file from
# install-helsinki-atc.sh's own behavior/root-check.
NOOP_DEPLOY="$TMP/noop-deploy.sh"
cat > "$NOOP_DEPLOY" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$NOOP_DEPLOY"

# ── 2. FAILED organ path: stub systemctl reports one failed service ────────
STUB="$TMP/systemctl-failed"
CALL_LOG="$TMP/calls.log"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALL_LOG"
case "\$1 \$2" in
    "list-units --all")
        echo "chump-sla-scorecard.service loaded failed failed Chump merge-SLA scorecard"
        exit 0
        ;;
esac
if [[ "\$1" == "list-units" ]]; then
    echo "chump-sla-scorecard.service loaded failed failed Chump merge-SLA scorecard"
    exit 0
fi
if [[ "\$1" == "list-unit-files" ]]; then
    exit 0
fi
if [[ "\$1" == "reset-failed" || "\$1" == "restart" ]]; then
    exit 0
fi
exit 0
EOF
chmod +x "$STUB"

AMB="$TMP/ambient.jsonl"
: > "$AMB"
out="$(CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB" CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT="$NOOP_DEPLOY" CHUMP_AMBIENT_LOG="$AMB" "$WATCHDOG" 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "watchdog exited $rc on the failed-organ path; output: $out"
echo "$out" | grep -q "healed chump-sla-scorecard.service" \
    || fail "expected healed log line; got: $out"
grep -q '"kind":"organ_self_healed"' "$AMB" \
    || fail "expected organ_self_healed emitted; ambient: $(cat "$AMB")"
grep -q '"unit":"chump-sla-scorecard.service"' "$AMB" \
    || fail "expected unit field naming the healed service; ambient: $(cat "$AMB")"
grep -q "reset-failed chump-sla-scorecard.service" "$CALL_LOG" \
    || fail "expected reset-failed to be called; calls: $(cat "$CALL_LOG")"
grep -q "restart chump-sla-scorecard.service" "$CALL_LOG" \
    || fail "expected restart to be called; calls: $(cat "$CALL_LOG")"
pass "kills a failed organ and watches it self-heal (reset-failed + restart), no human step"

# ── 3. Healthy fleet: nothing to heal, tick heartbeat still emitted ────────
STUB2="$TMP/systemctl-healthy"
cat > "$STUB2" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB2"
AMB2="$TMP/ambient2.jsonl"
: > "$AMB2"
out2="$(CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB2" CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT="$NOOP_DEPLOY" CHUMP_AMBIENT_LOG="$AMB2" "$WATCHDOG" 2>&1)"
rc2=$?
[[ "$rc2" -eq 0 ]] || fail "watchdog exited $rc2 on the healthy path; output: $out2"
echo "$out2" | grep -q "healed=0" || fail "expected healed=0 on a healthy fleet; got: $out2"
grep -q '"kind":"organ_watchdog_tick"' "$AMB2" \
    || fail "expected organ_watchdog_tick heartbeat; ambient: $(cat "$AMB2")"
pass "healthy fleet: heals nothing, still emits heartbeat tick"

# ── 4. --dry-run does not call reset-failed/restart ─────────────────────────
CALL_LOG3="$TMP/calls3.log"
STUB3="$TMP/systemctl-dryrun"
cat > "$STUB3" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALL_LOG3"
if [[ "\$1" == "list-units" ]]; then
    echo "chump-sla-scorecard.service loaded failed failed Chump merge-SLA scorecard"
    exit 0
fi
if [[ "\$1" == "list-unit-files" ]]; then
    exit 0
fi
exit 0
EOF
chmod +x "$STUB3"
AMB3="$TMP/ambient3.jsonl"
: > "$AMB3"
CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB3" CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT="$NOOP_DEPLOY" CHUMP_AMBIENT_LOG="$AMB3" "$WATCHDOG" --dry-run >/dev/null 2>&1
grep -q "reset-failed" "$CALL_LOG3" && fail "--dry-run must not call reset-failed; calls: $(cat "$CALL_LOG3")"
grep -q "restart" "$CALL_LOG3" && fail "--dry-run must not call restart; calls: $(cat "$CALL_LOG3")"
pass "--dry-run reports without mutating systemd state"

# ── 5. INFRA-3598: watchdog actually invokes the unit-deploy script ────────
# This is the false-done fix: node-refresh-chump.sh's call to
# install-helsinki-atc.sh --auto silently no-ops (unprivileged). The
# watchdog runs as root, so ITS call must be the one that actually happens,
# every cycle, unconditionally (not just on the failed-organ path).
STUB4="$TMP/systemctl-healthy4"
cat > "$STUB4" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB4"
DEPLOY_CALL_LOG="$TMP/deploy-calls.log"
DEPLOY_STUB="$TMP/deploy-stub.sh"
cat > "$DEPLOY_STUB" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$DEPLOY_CALL_LOG"
exit 0
EOF
chmod +x "$DEPLOY_STUB"
AMB4="$TMP/ambient4.jsonl"
: > "$AMB4"
CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB4" CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT="$DEPLOY_STUB" \
    CHUMP_AMBIENT_LOG="$AMB4" "$WATCHDOG" >/dev/null 2>&1
grep -q -- "--auto" "$DEPLOY_CALL_LOG" \
    || fail "expected the deploy script to be invoked with --auto every cycle; calls: $(cat "$DEPLOY_CALL_LOG" 2>/dev/null)"
pass "watchdog calls install-helsinki-atc.sh --auto every cycle (the privileged path node-refresh-chump.sh cannot reach)"

# ── 6. --dry-run does not invoke the deploy script ──────────────────────────
DEPLOY_CALL_LOG2="$TMP/deploy-calls2.log"
: > "$DEPLOY_CALL_LOG2"
DEPLOY_STUB2="$TMP/deploy-stub2.sh"
cat > "$DEPLOY_STUB2" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$DEPLOY_CALL_LOG2"
exit 0
EOF
chmod +x "$DEPLOY_STUB2"
AMB5="$TMP/ambient5.jsonl"
: > "$AMB5"
CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB4" CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT="$DEPLOY_STUB2" \
    CHUMP_AMBIENT_LOG="$AMB5" "$WATCHDOG" --dry-run >/dev/null 2>&1
[[ -s "$DEPLOY_CALL_LOG2" ]] && fail "--dry-run must not invoke the deploy script; calls: $(cat "$DEPLOY_CALL_LOG2")"
pass "--dry-run does not invoke the unit-deploy script"

# ── 7. CHUMP_ORGAN_WATCHDOG_CLONE_REFRESH=1 fast-forwards via stubbed git ──
GIT_CALL_LOG="$TMP/git-calls.log"
GIT_STUB="$TMP/git-stub.sh"
cat > "$GIT_STUB" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GIT_CALL_LOG"
case "\$*" in
    *"fetch origin main"*) exit 0 ;;
    *"rev-parse --short=12 HEAD"*) echo "aaaaaaaaaaaa"; exit 0 ;;
    *"rev-parse --short=12 origin/main"*) echo "bbbbbbbbbbbb"; exit 0 ;;
    *"reset --hard origin/main"*) exit 0 ;;
esac
exit 0
EOF
chmod +x "$GIT_STUB"
AMB6="$TMP/ambient6.jsonl"
: > "$AMB6"
CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB4" CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT="$NOOP_DEPLOY" \
    CHUMP_ORGAN_WATCHDOG_GIT_BIN="$GIT_STUB" CHUMP_ORGAN_WATCHDOG_CLONE_REFRESH=1 \
    CHUMP_AMBIENT_LOG="$AMB6" "$WATCHDOG" >/dev/null 2>&1
grep -q "reset --hard origin/main" "$GIT_CALL_LOG" \
    || fail "expected git reset --hard origin/main when SHAs diverge; calls: $(cat "$GIT_CALL_LOG")"
grep -q '"kind":"organ_clone_refreshed"' "$AMB6" \
    || fail "expected organ_clone_refreshed emitted; ambient: $(cat "$AMB6")"
pass "CHUMP_ORGAN_WATCHDOG_CLONE_REFRESH=1 fast-forwards the deploy clone before reconciling units"

# ── 8. clone refresh is off by default (no git calls at all) ───────────────
GIT_CALL_LOG2="$TMP/git-calls2.log"
GIT_STUB2="$TMP/git-stub2.sh"
cat > "$GIT_STUB2" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GIT_CALL_LOG2"
exit 0
EOF
chmod +x "$GIT_STUB2"
AMB7="$TMP/ambient7.jsonl"
: > "$AMB7"
CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB4" CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT="$NOOP_DEPLOY" \
    CHUMP_ORGAN_WATCHDOG_GIT_BIN="$GIT_STUB2" \
    CHUMP_AMBIENT_LOG="$AMB7" "$WATCHDOG" >/dev/null 2>&1
[[ -s "$GIT_CALL_LOG2" ]] && fail "clone refresh must default OFF (no git calls); calls: $(cat "$GIT_CALL_LOG2")"
pass "clone refresh defaults off — a dev/test checkout is never hard-reset unintentionally"

# ── 9-12. RESILIENT-324: worker-liveness alarm ──────────────────────────────
# 2026-08-14 incident: chump-worker@1/@2.service sat SIGTERM-stopped +
# disabled for 2.5h with no alarm. These prove the watchdog now (a) notices 0
# active gap-starter workers, (b) does NOT page immediately — only after a
# sustained threshold, (c) DOES page via operator-recall.sh once that
# threshold is crossed, (d) clears state + stays silent once a worker is
# active again, and (e) is a no-op on a host with no chump-worker@ template.

# Base stub: no failed services, no enabled-but-inactive timers, worker
# template present, both configured worker ids report inactive.
mk_worker_stub() {  # $1=stub path $2=call-log path $3=is-active exit code for chump-worker@*
    local stub="$1" log="$2" active_rc="$3"
    cat > "$stub" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$log"
if [[ "\$1" == "list-units" ]]; then
    exit 0
fi
if [[ "\$1" == "list-unit-files" && "\$*" == *"chump-worker@.service"* ]]; then
    echo "chump-worker@.service"
    exit 0
fi
if [[ "\$1" == "list-unit-files" ]]; then
    exit 0
fi
if [[ "\$1" == "is-active" && "\$*" == *"chump-worker@"* ]]; then
    exit $active_rc
fi
exit 0
EOF
    chmod +x "$stub"
}

RECALL_CALL_LOG="$TMP/recall-calls.log"
RECALL_STUB="$TMP/recall-stub.sh"
cat > "$RECALL_STUB" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$RECALL_CALL_LOG"
exit 0
EOF
chmod +x "$RECALL_STUB"

# ── 9. First cycle with 0 active workers: emits worker_liveness_zero, does
#      NOT page yet (age ~0s < CHUMP_WORKER_HALT_MIN_SECS) ─────────────────
STUB9="$TMP/systemctl-worker9"
CALL_LOG9="$TMP/calls9.log"
mk_worker_stub "$STUB9" "$CALL_LOG9" 1   # is-active exits 1 == inactive
AMB9="$TMP/ambient9.jsonl"
: > "$AMB9"
: > "$RECALL_CALL_LOG"
rm -f "$TMP/worker-halt-since.ts"
CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB9" CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT="$NOOP_DEPLOY" \
    CHUMP_ORGAN_WATCHDOG_RECALL_SCRIPT="$RECALL_STUB" CHUMP_WORKER_HALT_MIN_SECS=1800 \
    CHUMP_AMBIENT_LOG="$AMB9" "$WATCHDOG" >/dev/null 2>&1
grep -q '"kind":"worker_liveness_zero"' "$AMB9" \
    || fail "expected worker_liveness_zero emitted when 0 workers active; ambient: $(cat "$AMB9")"
[[ -s "$RECALL_CALL_LOG" ]] && fail "must NOT page on the first below-threshold cycle; calls: $(cat "$RECALL_CALL_LOG")"
[[ -f "$TMP/worker-halt-since.ts" ]] || fail "expected worker-halt-since.ts state file to be created"
pass "0 active workers: notices + emits worker_liveness_zero, does not page before the sustained threshold"

# ── 10. Sustained halt (state file pre-seeded old) → pages WORKER_HALT ─────
STUB10="$TMP/systemctl-worker10"
CALL_LOG10="$TMP/calls10.log"
mk_worker_stub "$STUB10" "$CALL_LOG10" 1
AMB10="$TMP/ambient10.jsonl"
: > "$AMB10"
: > "$RECALL_CALL_LOG"
old_ts=$(( $(date +%s) - 3600 ))
echo "$old_ts" > "$TMP/worker-halt-since.ts"
CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB10" CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT="$NOOP_DEPLOY" \
    CHUMP_ORGAN_WATCHDOG_RECALL_SCRIPT="$RECALL_STUB" CHUMP_WORKER_HALT_MIN_SECS=1800 \
    CHUMP_AMBIENT_LOG="$AMB10" "$WATCHDOG" >/dev/null 2>&1
grep -q -- "--condition WORKER_HALT" "$RECALL_CALL_LOG" \
    || fail "expected operator-recall.sh --condition WORKER_HALT after sustained halt; calls: $(cat "$RECALL_CALL_LOG" 2>/dev/null)"
pass "sustained 0-worker halt (>= threshold) pages the operator via WORKER_HALT"

# ── 11. A worker is active → no alarm, stale state file is cleared ─────────
STUB11="$TMP/systemctl-worker11"
CALL_LOG11="$TMP/calls11.log"
mk_worker_stub "$STUB11" "$CALL_LOG11" 0   # is-active exits 0 == active
AMB11="$TMP/ambient11.jsonl"
: > "$AMB11"
: > "$RECALL_CALL_LOG"
echo "$old_ts" > "$TMP/worker-halt-since.ts"
CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB11" CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT="$NOOP_DEPLOY" \
    CHUMP_ORGAN_WATCHDOG_RECALL_SCRIPT="$RECALL_STUB" CHUMP_WORKER_HALT_MIN_SECS=1800 \
    CHUMP_AMBIENT_LOG="$AMB11" "$WATCHDOG" >/dev/null 2>&1
grep -q '"kind":"worker_liveness_zero"' "$AMB11" \
    && fail "must not emit worker_liveness_zero when a worker is active; ambient: $(cat "$AMB11")"
[[ -s "$RECALL_CALL_LOG" ]] && fail "must not page when a worker is active; calls: $(cat "$RECALL_CALL_LOG")"
[[ -f "$TMP/worker-halt-since.ts" ]] && fail "expected stale worker-halt-since.ts to be cleared once a worker is active again"
pass "active worker: silent, and clears any stale halt-tracking state"

# ── 12. No chump-worker@.service template on this host → fully skipped ─────
STUB12="$TMP/systemctl-noworker12"
CALL_LOG12="$TMP/calls12.log"
cat > "$STUB12" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALL_LOG12"
exit 0
EOF
chmod +x "$STUB12"
AMB12="$TMP/ambient12.jsonl"
: > "$AMB12"
: > "$RECALL_CALL_LOG"
rm -f "$TMP/worker-halt-since.ts"
CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB12" CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT="$NOOP_DEPLOY" \
    CHUMP_ORGAN_WATCHDOG_RECALL_SCRIPT="$RECALL_STUB" CHUMP_WORKER_HALT_MIN_SECS=1800 \
    CHUMP_AMBIENT_LOG="$AMB12" "$WATCHDOG" >/dev/null 2>&1
grep -q '"kind":"worker_liveness_zero"' "$AMB12" \
    && fail "must not check worker liveness on a host with no chump-worker@ template; ambient: $(cat "$AMB12")"
[[ -f "$TMP/worker-halt-since.ts" ]] && fail "must not create halt-tracking state on a host with no chump-worker@ template"
pass "no chump-worker@.service template on this host: worker-liveness check is a full no-op"

# ── 13-17. RESILIENT-332: spinning-worker detection & heal ──────────────────
# 2026-08-15 incident: worker 2 emitted worker_stuck reason=preflight_fail 108x
# in 15min, re-picking two stale-open gaps and doing zero work while looking
# healthy to the heartbeat-based silent-worker watchdog. The OS emitted the
# signal 108x and nothing consumed it. These prove the watchdog now ACTS on
# its own worker_stuck stream: (13) restarts a spinning worker + clears the
# offending claim, (14) stays quiet below threshold, (15) --dry-run detects but
# does not mutate, (16) respects the per-worker heal-cooldown, (17) no-ops with
# no worker template.

# Seed N worker_stuck preflight_fail events for a given agent+gap, all "now".
seed_spin_events() {  # $1=ambient-file $2=agent $3=gap $4=count
    local amb="$1" agent="$2" gap="$3" n="$4" i ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for ((i=0; i<n; i++)); do
        printf '{"ts":"%s","kind":"worker_stuck","agent_id":"%s","session":"s","gap_id":"%s","reason":"preflight_fail: gap=%s claimed/done/missing"}\n' \
            "$ts" "$agent" "$gap" "$gap" >> "$amb"
    done
}

# Worker stub that also records restart calls and reports workers ACTIVE (so
# section 3's liveness path stays quiet and doesn't muddy the assertions).
STUB13="$TMP/systemctl-spin13"
CALL_LOG13="$TMP/calls13.log"
mk_worker_stub "$STUB13" "$CALL_LOG13" 0   # is-active exits 0 == active
AMB13="$TMP/ambient13.jsonl"
: > "$AMB13"
seed_spin_events "$AMB13" 2 INFRA-2088 25   # 25 >= default threshold 20
rm -f "$TMP/worker-spin-healed-2.ts" "$TMP/cooldown/INFRA-2088.json" "$TMP/.gap-INFRA-2088.lock"
CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB13" CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT="$NOOP_DEPLOY" \
    CHUMP_WORKER_HALT_MIN_SECS=999999 \
    CHUMP_AMBIENT_LOG="$AMB13" "$WATCHDOG" >/dev/null 2>&1
grep -q "restart chump-worker@2.service" "$CALL_LOG13" \
    || fail "expected the watchdog to restart the spinning worker@2; calls: $(cat "$CALL_LOG13")"
grep -q '"kind":"worker_spin_healed"' "$AMB13" \
    || fail "expected worker_spin_healed emitted; ambient tail: $(tail -3 "$AMB13")"
grep -q '"agent_id":"2"' "$AMB13" \
    || fail "expected the healed event to name agent 2"
[[ -f "$TMP/cooldown/INFRA-2088.json" ]] \
    || fail "expected the offending gap INFRA-2088 to be cooled down so it isn't re-picked post-restart"
[[ -f "$TMP/worker-spin-healed-2.ts" ]] \
    || fail "expected the per-worker heal-cooldown state file to be written"
pass "13: spinning worker (25x preflight_fail) → watchdog restarts worker@2 + clears the offending claim (acts on its own signal)"

# ── 14. Below threshold → no restart, no heal event ─────────────────────────
STUB14="$TMP/systemctl-spin14"
CALL_LOG14="$TMP/calls14.log"
mk_worker_stub "$STUB14" "$CALL_LOG14" 0
AMB14="$TMP/ambient14.jsonl"
: > "$AMB14"
seed_spin_events "$AMB14" 2 INFRA-2088 5    # 5 < threshold 20
rm -f "$TMP/worker-spin-healed-2.ts"
CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB14" CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT="$NOOP_DEPLOY" \
    CHUMP_WORKER_HALT_MIN_SECS=999999 \
    CHUMP_AMBIENT_LOG="$AMB14" "$WATCHDOG" >/dev/null 2>&1
grep -q "restart chump-worker@2.service" "$CALL_LOG14" \
    && fail "must NOT restart a worker below the spin threshold; calls: $(cat "$CALL_LOG14")"
grep -q '"kind":"worker_spin_healed"' "$AMB14" \
    && fail "must NOT emit worker_spin_healed below threshold; ambient: $(cat "$AMB14")"
pass "14: below the spin threshold (5x) → watchdog stays quiet (no false restarts)"

# ── 15. --dry-run detects but does not restart / mutate ─────────────────────
STUB15="$TMP/systemctl-spin15"
CALL_LOG15="$TMP/calls15.log"
mk_worker_stub "$STUB15" "$CALL_LOG15" 0
AMB15="$TMP/ambient15.jsonl"
: > "$AMB15"
seed_spin_events "$AMB15" 2 INFRA-2088 25
rm -f "$TMP/worker-spin-healed-2.ts" "$TMP/cooldown/INFRA-2088.json"
CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB15" CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT="$NOOP_DEPLOY" \
    CHUMP_WORKER_HALT_MIN_SECS=999999 \
    CHUMP_AMBIENT_LOG="$AMB15" "$WATCHDOG" --dry-run >/dev/null 2>&1
grep -q "restart chump-worker@2.service" "$CALL_LOG15" \
    && fail "--dry-run must NOT restart the worker; calls: $(cat "$CALL_LOG15")"
[[ -f "$TMP/cooldown/INFRA-2088.json" ]] \
    && fail "--dry-run must NOT write a cooldown; state mutated"
grep -q '"kind":"worker_spin_detected"' "$AMB15" \
    || fail "--dry-run should still DETECT + emit worker_spin_detected; ambient tail: $(tail -3 "$AMB15")"
pass "15: --dry-run detects the spin (worker_spin_detected) without restarting or mutating state"

# ── 16. Per-worker heal-cooldown suppresses a re-heal within the window ─────
STUB16="$TMP/systemctl-spin16"
CALL_LOG16="$TMP/calls16.log"
mk_worker_stub "$STUB16" "$CALL_LOG16" 0
AMB16="$TMP/ambient16.jsonl"
: > "$AMB16"
seed_spin_events "$AMB16" 2 INFRA-2088 25
# Pre-seed a recent heal so the watchdog should skip re-healing.
date +%s > "$TMP/worker-spin-healed-2.ts"
CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB16" CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT="$NOOP_DEPLOY" \
    CHUMP_WORKER_HALT_MIN_SECS=999999 CHUMP_WORKER_SPIN_HEAL_COOLDOWN_S=600 \
    CHUMP_AMBIENT_LOG="$AMB16" "$WATCHDOG" >/dev/null 2>&1
grep -q "restart chump-worker@2.service" "$CALL_LOG16" \
    && fail "must NOT re-heal a worker healed within the cooldown window; calls: $(cat "$CALL_LOG16")"
pass "16: heal-cooldown honored — no restart storm while stale worker_stuck events age out of the window"

# ── 17. No chump-worker@ template → spin heal fully skipped ──────────────────
STUB17="$TMP/systemctl-spin17"
CALL_LOG17="$TMP/calls17.log"
cat > "$STUB17" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALL_LOG17"
exit 0
EOF
chmod +x "$STUB17"
AMB17="$TMP/ambient17.jsonl"
: > "$AMB17"
seed_spin_events "$AMB17" 2 INFRA-2088 25
rm -f "$TMP/worker-spin-healed-2.ts"
CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB17" CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT="$NOOP_DEPLOY" \
    CHUMP_WORKER_HALT_MIN_SECS=999999 \
    CHUMP_AMBIENT_LOG="$AMB17" "$WATCHDOG" >/dev/null 2>&1
grep -q '"kind":"worker_spin_healed"' "$AMB17" \
    && fail "must not heal spin on a host with no chump-worker@ template; ambient: $(cat "$AMB17")"
[[ -f "$TMP/worker-spin-healed-2.ts" ]] \
    && fail "must not write spin-heal state on a host with no chump-worker@ template"
pass "17: no chump-worker@ template on this host: spin-heal is a full no-op"

# ── 18-19. RESILIENT-347: watchdog defers to organ-reconcile's backoff ──────
# organ-reconcile.sh disables + backs off a unit that fails to verify active,
# specifically so it is NOT re-attempted every cycle. Without this wiring,
# section 1's blind "any failed chump-*.service gets reset-failed+restart"
# loop would resurrect that exact unit every 5 minutes through the watchdog's
# own door — recreating the churn RESILIENT-347 exists to end. Backoff is
# recorded against the manifest unit (usually a .timer), so the watchdog must
# also consult the failed .service's .timer counterpart.
STUB18="$TMP/systemctl-backoff18"
CALL_LOG18="$TMP/calls18.log"
cat > "$STUB18" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALL_LOG18"
if [[ "\$1" == "list-units" ]]; then
    echo "chump-integrator.service loaded failed failed Chump batched merge train"
    exit 0
fi
if [[ "\$1" == "list-unit-files" ]]; then
    exit 0
fi
exit 0
EOF
chmod +x "$STUB18"
BACKOFF_DIR18="$TMP/organ-backoff18"
mkdir -p "$BACKOFF_DIR18"
printf '{"unit":"chump-integrator.timer","since":%d,"reason":"verify_failed"}\n' "$(date +%s)" \
    > "$BACKOFF_DIR18/chump-integrator.timer.json"
AMB18="$TMP/ambient18.jsonl"
: > "$AMB18"
CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB18" CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT="$NOOP_DEPLOY" \
    CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$BACKOFF_DIR18" \
    CHUMP_AMBIENT_LOG="$AMB18" "$WATCHDOG" >/dev/null 2>&1
grep -q "reset-failed chump-integrator.service" "$CALL_LOG18" \
    && fail "must NOT reset-failed a unit whose .timer counterpart is backed off; calls: $(cat "$CALL_LOG18")"
grep -q "restart chump-integrator.service" "$CALL_LOG18" \
    && fail "must NOT restart a unit whose .timer counterpart is backed off; calls: $(cat "$CALL_LOG18")"
grep -q '"kind":"organ_watchdog_backoff_skip"' "$AMB18" \
    || fail "expected organ_watchdog_backoff_skip emitted; ambient: $(cat "$AMB18")"
grep -q '"unit":"chump-integrator.service"' "$AMB18" \
    || fail "expected the skip event to name the backed-off service; ambient: $(cat "$AMB18")"
pass "18: a failed service whose .timer is in organ-reconcile backoff is SKIPPED, not resurrected (RESILIENT-347)"

# ── 19. Regression: a failed service with NO backoff record still heals ────
STUB19="$TMP/systemctl-backoff19"
CALL_LOG19="$TMP/calls19.log"
cat > "$STUB19" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALL_LOG19"
if [[ "\$1" == "list-units" ]]; then
    echo "chump-integrator.service loaded failed failed Chump batched merge train"
    exit 0
fi
if [[ "\$1" == "list-unit-files" ]]; then
    exit 0
fi
exit 0
EOF
chmod +x "$STUB19"
BACKOFF_DIR19="$TMP/organ-backoff19"
mkdir -p "$BACKOFF_DIR19"   # empty — no backoff record for this unit
AMB19="$TMP/ambient19.jsonl"
: > "$AMB19"
CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB19" CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT="$NOOP_DEPLOY" \
    CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$BACKOFF_DIR19" \
    CHUMP_AMBIENT_LOG="$AMB19" "$WATCHDOG" >/dev/null 2>&1
grep -q "reset-failed chump-integrator.service" "$CALL_LOG19" \
    || fail "expected reset-failed when there is no backoff record; calls: $(cat "$CALL_LOG19")"
grep -q "restart chump-integrator.service" "$CALL_LOG19" \
    || fail "expected restart when there is no backoff record; calls: $(cat "$CALL_LOG19")"
grep -q '"kind":"organ_self_healed"' "$AMB19" \
    || fail "expected organ_self_healed when there is no backoff record; ambient: $(cat "$AMB19")"
pass "19: a failed service with no backoff record still self-heals as before (no regression)"

# ── 20. RESILIENT-347 AC 3: organ-watchdog directly invokes organ-reconcile ─
# Proves the "wire organ-watchdog to run it" wiring: a stubbed
# organ-reconcile.sh must be called with `--apply` on a normal (non-dry-run)
# cycle, and must NOT be called under --dry-run.
STUB20="$TMP/systemctl-healthy20"
cat > "$STUB20" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB20"
RECONCILE_CALL_LOG20="$TMP/reconcile-calls20.log"
RECONCILE_STUB20="$TMP/reconcile-stub20.sh"
cat > "$RECONCILE_STUB20" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$RECONCILE_CALL_LOG20"
exit 0
EOF
chmod +x "$RECONCILE_STUB20"
AMB20="$TMP/ambient20.jsonl"
: > "$AMB20"
CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB20" CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT="$NOOP_DEPLOY" \
    CHUMP_ORGAN_WATCHDOG_RECONCILE_SCRIPT="$RECONCILE_STUB20" \
    CHUMP_AMBIENT_LOG="$AMB20" "$WATCHDOG" >/dev/null 2>&1
[[ -f "$RECONCILE_CALL_LOG20" ]] || fail "expected organ-reconcile.sh to be invoked at least once; nothing logged"
grep -q -- "--apply" "$RECONCILE_CALL_LOG20" \
    || fail "expected organ-reconcile.sh to be called with --apply; calls: $(cat "$RECONCILE_CALL_LOG20")"
pass "20: organ-watchdog directly invokes organ-reconcile.sh --apply every cycle (RESILIENT-347 AC 3)"

# ── 21. --dry-run must NOT invoke organ-reconcile.sh for real ──────────────
RECONCILE_CALL_LOG21="$TMP/reconcile-calls21.log"
RECONCILE_STUB21="$TMP/reconcile-stub21.sh"
cat > "$RECONCILE_STUB21" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$RECONCILE_CALL_LOG21"
exit 0
EOF
chmod +x "$RECONCILE_STUB21"
AMB21="$TMP/ambient21.jsonl"
: > "$AMB21"
CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB20" CHUMP_ORGAN_WATCHDOG_DEPLOY_SCRIPT="$NOOP_DEPLOY" \
    CHUMP_ORGAN_WATCHDOG_RECONCILE_SCRIPT="$RECONCILE_STUB21" \
    CHUMP_AMBIENT_LOG="$AMB21" "$WATCHDOG" --dry-run >/dev/null 2>&1
[[ -f "$RECONCILE_CALL_LOG21" ]] && fail "organ-reconcile.sh must NOT run for real under --dry-run; calls: $(cat "$RECONCILE_CALL_LOG21")"
pass "21: --dry-run does not invoke organ-reconcile.sh for real"

echo "ALL PASS"
