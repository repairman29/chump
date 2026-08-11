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

echo "ALL PASS"
