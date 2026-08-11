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
out="$(CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB" CHUMP_AMBIENT_LOG="$AMB" "$WATCHDOG" 2>&1)"
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
out2="$(CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB2" CHUMP_AMBIENT_LOG="$AMB2" "$WATCHDOG" 2>&1)"
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
CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN="$STUB3" CHUMP_AMBIENT_LOG="$AMB3" "$WATCHDOG" --dry-run >/dev/null 2>&1
grep -q "reset-failed" "$CALL_LOG3" && fail "--dry-run must not call reset-failed; calls: $(cat "$CALL_LOG3")"
grep -q "restart" "$CALL_LOG3" && fail "--dry-run must not call restart; calls: $(cat "$CALL_LOG3")"
pass "--dry-run reports without mutating systemd state"

echo "ALL PASS"
