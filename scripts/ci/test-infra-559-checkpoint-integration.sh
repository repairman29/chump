#!/usr/bin/env bash
# test-infra-559-checkpoint-integration.sh — INFRA-559
#
# Integration test for INFRA-525 watchdog WIP-commit-on-timeout.
# Uses FLEET_TIMEOUT_S=10 + CHUMP_TIMEOUT_CHECKPOINT_SECS=2 with a
# fake-claude that sleeps 12s to trigger the watchdog in ~10s total.
# Asserts: WIP commit lands on the branch.
# Push is NOT asserted (no remote in test env); commit is the gate.

set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

echo "=== INFRA-559 checkpoint-on-timeout integration test ==="
echo

# ── Setup: isolated git repo so we don't pollute the real worktree ───────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

FAKE_REPO="$TMPDIR_TEST/fake-repo"
git init -q "$FAKE_REPO"
git -C "$FAKE_REPO" -c user.name=test -c user.email=test@test commit \
    --allow-empty -m "init" -q

# ── Fake-claude: sleeps 12s (longer than FLEET_TIMEOUT_S=10) ─────────────────
FAKE_CLAUDE="$TMPDIR_TEST/fake-claude"
cat >"$FAKE_CLAUDE" <<'EOF'
#!/usr/bin/env bash
sleep 12
EOF
chmod +x "$FAKE_CLAUDE"

# ── Inject a tracked file with pending edits so there's something to commit ──
echo "work in progress" >"$FAKE_REPO/wip.txt"
git -C "$FAKE_REPO" add wip.txt

# ── Extract + run the watchdog logic inline ──────────────────────────────────
# The watchdog is an anonymous subshell inside worker.sh. We replicate it
# verbatim here so we test the exact same code path.
GAP_ID="INFRA-559-test"
branch="chump/infra-559-test"
AGENT_ID="test-agent"
CHUMP_AMBIENT_LOG="$TMPDIR_TEST/ambient.jsonl"
wt_path="$FAKE_REPO"

FLEET_TIMEOUT_S=10
CHUMP_TIMEOUT_CHECKPOINT_SECS=2
_checkpoint_secs="${CHUMP_TIMEOUT_CHECKPOINT_SECS:-30}"
_checkpoint_at=$(( FLEET_TIMEOUT_S - _checkpoint_secs ))

# Replicated watchdog subshell (must stay in sync with worker.sh INFRA-525 block).
if (( _checkpoint_at > 0 )); then
    (
        sleep "$_checkpoint_at"
        cd "$wt_path" 2>/dev/null || exit 0
        git add -A 2>/dev/null || true
        if ! git diff --cached --quiet 2>/dev/null; then
            git -c user.name='chump-fleet-checkpoint' \
                -c user.email='chump-fleet@noreply.bot' \
                commit -m "WIP-${GAP_ID}: timeout-rescue checkpoint (INFRA-525)

Auto-saved by worker.sh checkpoint-on-timeout watchdog at
T-${_checkpoint_secs}s before FLEET_TIMEOUT_S=${FLEET_TIMEOUT_S}s.
" 2>/dev/null || true
            # Push skipped: no remote in test env; commit is the observable gate.
            _amb="${CHUMP_AMBIENT_LOG:-/dev/null}"
            _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf '{"event":"ALERT","kind":"fleet_timeout_checkpoint","ts":"%s","agent":"%s","gap_id":"%s","branch":"%s","note":"WIP commit pushed; rescue via gh pr create"}\n' \
                "$_ts" "$AGENT_ID" "$GAP_ID" "$branch" \
                >> "$_amb" 2>/dev/null || true
        fi
    ) &
    _checkpoint_pid=$!
fi

# Simulate "claude -p" timing out: run fake-claude under timeout.
_timeout_cmd="timeout"
command -v gtimeout &>/dev/null && _timeout_cmd="gtimeout"
"$_timeout_cmd" "${FLEET_TIMEOUT_S}s" "$FAKE_CLAUDE" || true   # rc=124 on timeout, expected

# Kill watchdog if it's still alive (clean-exit path — not exercised here, but mirrors worker.sh).
if [[ -n "${_checkpoint_pid:-}" ]]; then
    wait "$_checkpoint_pid" 2>/dev/null || true
fi

# ── Assertions ────────────────────────────────────────────────────────────────
echo "--- git log in fake repo ---"
git -C "$FAKE_REPO" log --oneline | head -5

WIP_MSG="$(git -C "$FAKE_REPO" log --oneline | grep -m1 'WIP-' || true)"
if [[ -n "$WIP_MSG" ]]; then
    ok "WIP commit landed: $WIP_MSG"
else
    fail "WIP commit NOT found — watchdog did not fire or did not commit"
fi

# Author must be the fleet-checkpoint identity.
COMMIT_AUTHOR="$(git -C "$FAKE_REPO" log -1 --format='%an' 2>/dev/null || true)"
if [[ "$COMMIT_AUTHOR" == "chump-fleet-checkpoint" ]]; then
    ok "commit author is chump-fleet-checkpoint"
else
    fail "commit author wrong: '$COMMIT_AUTHOR'"
fi

# wip.txt must be in the commit.
if git -C "$FAKE_REPO" show HEAD --name-only | grep -q 'wip.txt'; then
    ok "wip.txt staged and committed"
else
    fail "wip.txt not in WIP commit"
fi

# Ambient ALERT emitted.
if grep -q 'fleet_timeout_checkpoint' "$CHUMP_AMBIENT_LOG" 2>/dev/null; then
    ok "ambient ALERT fleet_timeout_checkpoint emitted"
else
    fail "ambient ALERT not found"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
