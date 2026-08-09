#!/usr/bin/env bash
# RESILIENT-263: guard the operator escalation channel.
#
# WHY THIS TEST IS SHAPED THIS WAY. The failure mode being guarded is not "the
# notifier is broken" — it is "the notifier silently does nothing and everyone
# assumes someone was told." Two real instances:
#
#   * The operator-recall handler (INFRA-665) has been configured-but-dead since
#     2026-05-08 — enabled=true in the toml, zero processes running.
#   * pr-failure-auto-rescue recorded an outcome literally named `operator_alert`
#     that wrote a log line and alerted nobody, and closed PR #3510 on a false
#     red while the operator learned of it hours later by asking.
#
# So this asserts WIRING and SAFETY, not delivery. Delivery is proven by an
# actual send during development (done: HTTP 200 from a worktree), because a
# green "the function was called" test is exactly how the dead handler passed
# for three months.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== RESILIENT-263: operator escalation channel ==="

LIB="$REPO_ROOT/scripts/coord/lib/notify-operator.sh"
RESCUE="$REPO_ROOT/scripts/coord/pr-failure-auto-rescue.sh"

[[ -f "$LIB" ]] && ok "notify-operator.sh exists" || bad "notify-operator.sh missing"

# 1. The daemon must actually CALL it — the whole bug was a named-but-unwired alert.
if grep -q "notify_operator" "$RESCUE"; then
    ok "pr-failure-auto-rescue calls notify_operator"
else
    bad "pr-failure-auto-rescue does NOT call notify_operator (the INFRA-1600 bug)"
fi

# 2. The close path is where a line actually stops. It must notify.
if awk '/terminal_dispose.*closed_refiled/,/^}/' "$RESCUE" | grep -q "notify_operator"; then
    ok "the PR-close path notifies the operator"
else
    bad "the PR-close path does NOT notify — PR #3510 died here unannounced"
fi

# 3. `operator_alert` must alert an operator. It is named that.
if awk '/operator_alert/,/return 0/' "$RESCUE" | grep -q "notify_operator"; then
    ok "operator_alert outcome actually alerts the operator"
else
    bad "operator_alert still alerts nobody"
fi

# 4. NEVER print the token. Non-negotiable.
if grep -nE '(echo|printf|say)[^|]*\$\{?(token|TOKEN)' "$LIB" | grep -qv 'redacted'; then
    bad "notify-operator may print the token"
else
    ok "token is never echoed"
fi

# 5. A broken notifier must not take down the daemon it reports on.
if grep -q 'notify_operator() { echo "\[notify-operator\] MISSING' "$RESCUE"; then
    ok "missing helper degrades to a no-op (daemon still runs)"
else
    bad "no fallback — a missing helper could break PR automation"
fi

# 6. Worktree resolution. .env is gitignored and lives only in the main
#    checkout, while `chump claim` creates a worktree per gap. Without this the
#    alert is dead exactly when it is needed. Found by a real send, not review.
if grep -q "git-common-dir" "$LIB"; then
    ok "resolves .env from a worktree via git-common-dir"
else
    bad "no worktree fallback — alerts will silently skip from claim worktrees"
fi

# 7. Unconfigured must be a quiet no-op, not a crash, and must exit 0.
out="$(bash -c "unset DISCORD_TOKEN CHUMP_READY_DM_USER_ID; CHUMP_HOME=/nonexistent-$$; \
     cd /tmp && source '$LIB' 2>/dev/null && notify_operator 'x' 2>&1")"; rc=$?
if [[ $rc -eq 0 ]]; then
    ok "unconfigured is a no-op with exit 0 (rc=$rc)"
else
    bad "unconfigured returned rc=$rc — must never break the caller"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
echo "PASS"
