#!/usr/bin/env bash
# test-disk-reactor-halt-recovery.sh — RESILIENT-326
#
# Governance: no organ may halt/disable the fleet without a TESTED
# auto-recovery path + a loud page. scripts/coord/disk-critical-reactor.sh's
# quiesce_and_reclaim() sets AUTONOMY_LEVEL=0 to halt the fleet before
# pruning an over-cap shared cargo target — but before RESILIENT-326 it never
# restored the level on EITHER exit path (reclaimed or aborted), so a
# disk-critical quiesce could leave the fleet halted forever (the same
# failure class the back-pressure breaker hit in RESILIENT-324).
#
# This test proves both exit paths auto-resume AND page the operator, using
# the script's test hooks (CHUMP_SHARED_TARGET_GB_OVERRIDE, CHUMP_AUTON_FILE,
# CHUMP_AMBIENT_LOG, CHUMP_REPO) with systemctl-adjacent commands stubbed on
# PATH so nothing real is touched.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REACTOR="$REPO_ROOT/scripts/coord/disk-critical-reactor.sh"
[[ -f "$REACTOR" ]] || { echo "FAIL: $REACTOR not found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STUB="$TMP/bin"; mkdir -p "$STUB"
for cmd in tmux launchctl pkill; do
    cat > "$STUB/$cmd" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$STUB/$cmd"
done
export PATH="$STUB:$PATH"

PASS=0
FAIL=0
ok(){ echo "[PASS] $1"; PASS=$((PASS+1)); }
bad(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# Fake repo root: REAPER/RECALL scripts are absent-but-checked-for-executable,
# so quiesce_and_reclaim's own halt/resume logic runs standalone. RECALL is a
# stub that records whether it was invoked (proves the "loud page").
FAKE_REPO="$TMP/fake-repo"
mkdir -p "$FAKE_REPO/scripts/dispatch" "$FAKE_REPO/scripts/coord"
RECALL_LOG="$TMP/recall-calls.log"
cat > "$FAKE_REPO/scripts/dispatch/operator-recall.sh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$RECALL_LOG"
exit 0
EOF
chmod +x "$FAKE_REPO/scripts/dispatch/operator-recall.sh"

# ── Test 1: reclaimed path (no builds holding the target) restores autonomy ──
AUTON="$TMP/AUTONOMY_LEVEL"
AMBIENT="$TMP/ambient-reclaimed.jsonl"
echo 5 > "$AUTON"
cat > "$STUB/ps" <<'EOF'
#!/usr/bin/env bash
echo "USER PID TTY STAT TIME COMMAND"
EOF
chmod +x "$STUB/ps"

CHUMP_REPO="$FAKE_REPO" \
CHUMP_AMBIENT_LOG="$AMBIENT" \
CHUMP_AUTON_FILE="$AUTON" \
CHUMP_SHARED_TARGET_GB_OVERRIDE=100 \
CHUMP_SHARED_TARGET_CAP_GB=50 \
CHUMP_DISK_REACTOR_QUIESCE_EXECUTE=1 \
CHUMP_SHARED_TARGET="$TMP/shared-target-does-not-exist" \
    bash "$REACTOR" --quiesce-check
rc=$?

[[ "$rc" == "0" ]] && ok "reclaimed path: quiesce_and_reclaim returns 0" \
    || bad "reclaimed path: expected exit 0, got $rc"

restored="$(cat "$AUTON" 2>/dev/null || echo MISSING)"
[[ "$restored" == "5" ]] && ok "reclaimed path: AUTONOMY_LEVEL restored to prior value (5)" \
    || bad "reclaimed path: AUTONOMY_LEVEL not restored — found '$restored' (permanent-halt regression)"

grep -q '"kind":"disk_reactor_autonomy_halt"' "$AMBIENT" 2>/dev/null \
    && ok "reclaimed path: emits disk_reactor_autonomy_halt" \
    || bad "reclaimed path: missing disk_reactor_autonomy_halt emit"

grep -q '"kind":"disk_reactor_autonomy_resume"' "$AMBIENT" 2>/dev/null \
    && ok "reclaimed path: emits disk_reactor_autonomy_resume" \
    || bad "reclaimed path: missing disk_reactor_autonomy_resume emit"

[[ -s "$RECALL_LOG" ]] && grep -q "DISK_CRITICAL" "$RECALL_LOG" \
    && ok "reclaimed path: operator-recall.sh paged with DISK_CRITICAL (loud page)" \
    || bad "reclaimed path: operator was not paged on halt"

# ── Test 2: aborted path (a build still holds the target) also restores ─────
AUTON2="$TMP/AUTONOMY_LEVEL_2"
AMBIENT2="$TMP/ambient-aborted.jsonl"
RECALL_LOG2="$TMP/recall-calls-2.log"
echo 5 > "$AUTON2"
sed -i.bak "s#$RECALL_LOG#$RECALL_LOG2#" "$FAKE_REPO/scripts/dispatch/operator-recall.sh"
rm -f "$FAKE_REPO/scripts/dispatch/operator-recall.sh.bak"
cat > "$STUB/ps" <<'EOF'
#!/usr/bin/env bash
echo "USER PID TTY STAT TIME COMMAND"
echo "root 1234 pts/0 R 0:01 cargo build --release"
EOF
chmod +x "$STUB/ps"

CHUMP_REPO="$FAKE_REPO" \
CHUMP_AMBIENT_LOG="$AMBIENT2" \
CHUMP_AUTON_FILE="$AUTON2" \
CHUMP_SHARED_TARGET_GB_OVERRIDE=100 \
CHUMP_SHARED_TARGET_CAP_GB=50 \
CHUMP_DISK_REACTOR_QUIESCE_EXECUTE=1 \
CHUMP_DISK_REACTOR_QUIESCE_WAIT_S=2 \
CHUMP_SHARED_TARGET="$TMP/shared-target-does-not-exist-2" \
    bash "$REACTOR" --quiesce-check
rc2=$?

[[ "$rc2" == "1" ]] && ok "aborted path: quiesce_and_reclaim returns 1 (build still holding target)" \
    || bad "aborted path: expected exit 1, got $rc2"

restored2="$(cat "$AUTON2" 2>/dev/null || echo MISSING)"
[[ "$restored2" == "5" ]] && ok "aborted path: AUTONOMY_LEVEL restored to prior value (5) even on abort" \
    || bad "aborted path: AUTONOMY_LEVEL not restored on abort — found '$restored2' (permanent-halt regression)"

grep -q '"kind":"disk_reactor_quiesce_aborted"' "$AMBIENT2" 2>/dev/null \
    && ok "aborted path: emits disk_reactor_quiesce_aborted" \
    || bad "aborted path: missing disk_reactor_quiesce_aborted emit"

grep -q '"kind":"disk_reactor_autonomy_resume".*"reason":"aborted"' "$AMBIENT2" 2>/dev/null \
    && ok "aborted path: emits disk_reactor_autonomy_resume reason=aborted" \
    || bad "aborted path: missing disk_reactor_autonomy_resume(reason=aborted) emit"

echo
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" == "0" ]] || exit 1
exit 0
