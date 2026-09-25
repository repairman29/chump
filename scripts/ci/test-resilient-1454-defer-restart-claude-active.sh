#!/usr/bin/env bash
# scripts/ci/test-resilient-1454-defer-restart-claude-active.sh — RESILIENT-1454
#
# RESILIENT-1453 taught node-converge.sh to externally `systemctl restart` a
# chump-node*-worker.service the instant its worker.sh changes underneath it,
# relying on worker.sh's INFRA-686 SIGTERM/WIP checkpoint to make that safe at
# ANY point. But when the worker is blocked deep in an active `claude -p`
# child (mid-gap), the checkpoint races that still-running process and can run
# long enough to blow past systemd's TimeoutStopSec=90s — SIGKILLing the gap
# subprocess and losing the in-flight work instead of checkpointing it.
#
# Fix: _worker_has_active_claude_child() probes the unit's cgroup for a
# `claude -p` descendant; when one is active, the restart is DEFERRED to the
# next converge tick (a cycle boundary) rather than fired immediately.
#
# Tests:
#   1. bash -n passes
#   2. _worker_has_active_claude_child + defer wiring present in the script
#   3. a unit with an ACTIVE claude -p child (injected via the test-hook env
#      var) is NOT restarted; worker_restart_deferred_claude_active fires
#      instead of worker_restarted_on_code_change
#   4. a unit with NO active claude -p child restarts exactly as before
#      (worker_restarted_on_code_change fires, restart marker armed)
#   5. deferring a unit does NOT arm the 25min loop-guard marker (so the next
#      tick re-checks it rather than silently skipping for 25min)

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/ops/node-converge.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$SCRIPT" ] || fail "missing $SCRIPT"
bash -n "$SCRIPT" || fail "syntax error in $SCRIPT"
ok "bash -n passes"

grep -q "_worker_has_active_claude_child" "$SCRIPT" \
    || fail "_worker_has_active_claude_child helper not found in $SCRIPT"
grep -q "worker_restart_deferred_claude_active" "$SCRIPT" \
    || fail "worker_restart_deferred_claude_active emit not found in $SCRIPT"
ok "claude-active-child probe + deferral wiring present"

# ── Fixture: bare origin + a checkout clone, worker.sh changes on origin ────
ORIGIN="$TMP/origin.git"
CHECKOUT="$TMP/checkout"
git init --bare -q "$ORIGIN"
git clone -q "$ORIGIN" "$CHECKOUT"
git -C "$CHECKOUT" config user.email test@example.com
git -C "$CHECKOUT" config user.name "Test"

mkdir -p "$CHECKOUT/scripts/dispatch"
printf 'echo OLD\n' > "$CHECKOUT/scripts/dispatch/worker.sh"
git -C "$CHECKOUT" add scripts/dispatch/worker.sh
git -C "$CHECKOUT" commit -q -m "base"
git -C "$CHECKOUT" push -q origin HEAD:main
BASE_SHA="$(git -C "$CHECKOUT" rev-parse HEAD)"

printf 'echo NEW\n' > "$CHECKOUT/scripts/dispatch/worker.sh"
git -C "$CHECKOUT" commit -q -am "merged worker.sh fix"
git -C "$CHECKOUT" push -q origin HEAD:main
git -C "$CHECKOUT" reset --hard -q "$BASE_SHA"

AMBIENT="$TMP/.chump-locks/ambient.jsonl"
mkdir -p "$TMP/.chump-locks"

# Stub systemctl + sudo so the script believes exactly one worker unit is
# running, and stub the claude-child probe via the test-hook env var.
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "list-units" ]]; then
    echo "chump-node1-worker.service loaded active running Chump worker"
    exit 0
fi
if [[ "$1" == "show" ]]; then
    echo "/system.slice/chump-node1-worker.service"
    exit 0
fi
if [[ "$1" == "restart" ]]; then
    echo "restarted:$2" >> "$RESTART_LOG"
    exit 0
fi
exit 0
EOF
chmod +x "$BIN/systemctl"
cat > "$BIN/sudo" <<'EOF'
#!/usr/bin/env bash
# `sudo -n systemctl restart X` — drop the -n and delegate.
shift
exec "$@"
EOF
chmod +x "$BIN/sudo"

CLAUDE_ACTIVE_PROBE="$TMP/claude_active.sh"
cat > "$CLAUDE_ACTIVE_PROBE" <<'EOF'
#!/usr/bin/env bash
[[ "${CLAUDE_ACTIVE:-0}" == "1" ]] && exit 0
exit 1
EOF
chmod +x "$CLAUDE_ACTIVE_PROBE"

run_converge() {
    RESTART_LOG="$TMP/restart.log"; : > "$RESTART_LOG"
    PATH="$BIN:$PATH" \
    CHUMP_NODE_REPO="$CHECKOUT" \
    NODE_AMBIENT="$AMBIENT" \
    CHUMP_NODE_CONVERGE_LOGDIR="$TMP/logs" \
    CHUMP_NODE_CONVERGE_CLAUDE_CHECK_OVERRIDE="$CLAUDE_ACTIVE_PROBE" \
    CLAUDE_ACTIVE="${1:-0}" \
    RESTART_LOG="$RESTART_LOG" \
    HOME="$TMP/fakehome" \
        bash "$SCRIPT" > "$TMP/out.log" 2>&1
}

# ── Test: active claude -p child → restart deferred, not fired ─────────────
: > "$AMBIENT"
run_converge 1 || fail "converge exited non-zero (active-claude case): $(cat "$TMP/out.log")"
[ -s "$TMP/restart.log" ] && fail "restart WAS fired despite an active claude -p child: $(cat "$TMP/restart.log")"
grep -q '"kind":"worker_restart_deferred_claude_active"' "$AMBIENT" \
    || fail "expected worker_restart_deferred_claude_active: $(cat "$AMBIENT")"
grep -q '"kind":"worker_restarted_on_code_change"' "$AMBIENT" \
    && fail "worker_restarted_on_code_change fired despite the deferral"
ok "active claude -p child → restart deferred to next tick, no SIGTERM sent"

[ -f "$CHECKOUT/.chump-locks/worker-restart.marker" ] \
    && fail "loop-guard marker was armed despite a full deferral (would block the next tick's retry)"
ok "deferral does not arm the 25min loop-guard marker"

# ── Test: no active claude -p child → restart fires exactly as RESILIENT-1453 ──
git -C "$CHECKOUT" reset --hard -q "$BASE_SHA"
rm -f "$CHECKOUT/.chump-locks/worker-restart.marker" "$CHECKOUT/.chump-locks/worker-code.stamp"
: > "$AMBIENT"
run_converge 0 || fail "converge exited non-zero (idle case): $(cat "$TMP/out.log")"
grep -q "restarted:chump-node1-worker.service" "$TMP/restart.log" \
    || fail "restart was NOT fired with no active claude -p child: $(cat "$TMP/restart.log")"
grep -q '"kind":"worker_restarted_on_code_change"' "$AMBIENT" \
    || fail "expected worker_restarted_on_code_change: $(cat "$AMBIENT")"
grep -q '"kind":"worker_restart_deferred_claude_active"' "$AMBIENT" \
    && fail "deferred event fired despite no active claude -p child"
ok "no active claude -p child → restart fires immediately (RESILIENT-1453 behavior preserved)"

printf '\033[0;32mALL PASS\033[0m scripts/ci/test-resilient-1454-defer-restart-claude-active.sh\n'
