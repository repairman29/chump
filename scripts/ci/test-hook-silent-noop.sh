#!/usr/bin/env bash
# scripts/ci/test-hook-silent-noop.sh — INFRA-1988 (THE FLOOR Phase 2)
#
# Validates the runtime silent-noop alarm in scripts/git-hooks/pre-push.
# Invokes the hook with various stdin shapes and asserts:
#   1. Empty stdin → no event (trivial)
#   2. All-zero SHAs (new-branch push) → no event (trivial)
#   3. Real refs + loop body executed → no event (loud success)
#   4. Real refs + loop body SKIPPED by an early-exit guard → event fires
#
# Test (4) is the regression we're trying to prevent — exactly the
# INFRA-1986 silent-exit pattern that disabled Guard 3 for 3 days.
#
# W-013 immunization (RESILIENT-024 pattern): unset workflow-injected env.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-1988 hook silent-noop alarm tests ==="
echo

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"

[[ -x "$HOOK" ]] || { echo "FATAL: $HOOK not executable"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# W-013 immunization
unset CHUMP_REPO CHUMP_LOCK_DIR

# Source-contract: verify the sentinel + EXIT trap are present.
echo "--- Source-contract assertions ---"
for needle in \
    "_HOOK_LOOP_ENTERED=0" \
    "_HOOK_LOOP_ENTERED=1" \
    "_silent_alarm_check_and_emit" \
    "trap _silent_alarm_check_and_emit EXIT" \
    "hook_silent_passthrough"; do
    if grep -qF "$needle" "$HOOK"; then
        ok "pre-push: $needle"
    else
        fail "pre-push missing: $needle"
    fi
done

# The 4 runtime cases need a controlled env. We point CHUMP_AMBIENT_LOG
# at our $TMP file and invoke pre-push with bypasses that prevent the
# hook from doing actual git ops (we just want to validate the alarm).

run_hook() {
    local stdin="$1"
    > "$TMP/ambient.jsonl"
    # INFRA-2422: CHUMP_PREFLIGHT_SKIP deleted. Skip preflight in the hook by
    # prepending a fake PATH dir that has no 'chump' binary — the hook's
    # guard condition (command -v chump) fails, so preflight is skipped.
    local fake_path_dir="$TMP/fake-path"
    mkdir -p "$fake_path_dir"
    echo "$stdin" | \
        PATH="$fake_path_dir:$PATH" \
        CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl" \
        CHUMP_AUTOMERGE_OVERRIDE=1 \
        CHUMP_GAP_CHECK=0 \
        CHUMP_FMT_CHECK=0 \
        CHUMP_TEST_GATE=0 \
        CHUMP_FORCE_LEASE_CHECK=0 \
        CHUMP_CI_REGRESSION_GUARD=0 \
        CHUMP_MERGE_PREVIEW=0 \
        bash "$HOOK" "origin" "https://example.com/repo.git" 2>&1
    cat "$TMP/ambient.jsonl" 2>/dev/null
}

# ── Test 1: empty stdin → no event ──────────────────────────────────────────
echo
echo "--- Test 1: empty stdin → no silent-passthrough event ---"
OUT=$(run_hook "")
EVT="$(grep "hook_silent_passthrough" "$TMP/ambient.jsonl" 2>/dev/null | wc -l | xargs)"
EVT="${EVT:-0}"
if [[ "$EVT" == "0" ]]; then
    ok "empty stdin produced no event (trivial push exempted)"
else
    fail "empty stdin should NOT emit silent-passthrough (events=$EVT, out=$OUT)"
fi

# ── Test 2: all-zero SHAs → no event (new branch) ──────────────────────────
echo
echo "--- Test 2: all-zero SHAs (new-branch push) → no event ---"
ZERO="0000000000000000000000000000000000000000"
OUT=$(run_hook "refs/heads/feature $ZERO refs/heads/feature $ZERO")
EVT="$(grep "hook_silent_passthrough" "$TMP/ambient.jsonl" 2>/dev/null | wc -l | xargs)"
EVT="${EVT:-0}"
if [[ "$EVT" == "0" ]]; then
    ok "all-zero SHAs produced no event (trivial push exempted)"
else
    fail "all-zero SHAs should NOT emit (events=$EVT)"
fi

# ── Test 3: real refs + main/master skip → main loop skip, but the loop
# body still 'entered' enough to set the flag (continue on master). ──────────
# Note: when branch is main/master, line 905 hits `continue` BUT the loop
# body did execute (variable was set BEFORE the continue). So _HOOK_LOOP_ENTERED=1
# and no alarm. Verify:
echo
echo "--- Test 3: real refs to main → continue, but _HOOK_LOOP_ENTERED=1 → no event ---"
OUT=$(run_hook "refs/heads/main aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/main bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
EVT="$(grep "hook_silent_passthrough" "$TMP/ambient.jsonl" 2>/dev/null | wc -l | xargs)"
EVT="${EVT:-0}"
if [[ "$EVT" == "0" ]]; then
    ok "loop body executed → no event (loud-success path)"
else
    fail "loop entered should NOT emit (events=$EVT, out=$OUT)"
fi

# ── Test 4: simulate INFRA-1986 — stdin drained before main loop ────────────
# We can't easily inject a drain into the live hook without modifying it.
# Instead, prove the alarm fires by manually invoking the EXIT trap with
# _HOOK_LOOP_ENTERED=0 and non-trivial stdin.
echo
echo "--- Test 4: synthetic INFRA-1986 reproduction (loop never entered) → event fires ---"
cat > "$TMP/synthetic-hook.sh" <<'SYN'
#!/usr/bin/env bash
set -uo pipefail
_HOOK_STDIN="$(cat || true)"
_HOOK_LOOP_ENTERED=0
_HOOK_NAME="pre-push"
_silent_alarm_check_and_emit() {
    local rc="$?"
    [[ "$rc" -ne 0 ]] && return "$rc"
    local _stdin_nontrivial=0
    if [[ -n "$_HOOK_STDIN" ]]; then
        if echo "$_HOOK_STDIN" | awk '$2 !~ /^0+$/ || $4 !~ /^0+$/ {found=1} END {exit !found}' 2>/dev/null; then
            _stdin_nontrivial=1
        fi
    fi
    if [[ "$_HOOK_LOOP_ENTERED" -eq 0 ]] && [[ "$_stdin_nontrivial" -eq 1 ]]; then
        printf '{"ts":"%s","kind":"hook_silent_passthrough","source":"pre_push_hook","hook":"%s","reason":"main_loop_did_not_execute_on_nontrivial_push","stdin_lines":%d}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$_HOOK_NAME" \
            "$(echo "$_HOOK_STDIN" | wc -l | xargs)" \
            >> "${CHUMP_AMBIENT_LOG}" 2>/dev/null || true
    fi
    return "$rc"
}
trap _silent_alarm_check_and_emit EXIT
# Simulate the bug: drain stdin in a side loop, never enter main loop.
echo "$_HOOK_STDIN" | while read -r _; do : ; done
# Main loop reads from real stdin (now empty) — exits without entering body.
while read -r local_ref local_sha remote_ref remote_sha; do
    _HOOK_LOOP_ENTERED=1
    echo "would process: $local_ref"
done
exit 0
SYN
chmod +x "$TMP/synthetic-hook.sh"
> "$TMP/ambient.jsonl"
echo "refs/heads/feature aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/feature bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    | CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl" \
      bash "$TMP/synthetic-hook.sh" "origin" "https://example.com/repo.git" 2>&1 >/dev/null

EVT="$(grep "hook_silent_passthrough" "$TMP/ambient.jsonl" 2>/dev/null | wc -l | xargs)"
EVT="${EVT:-0}"
if [[ "$EVT" -ge 1 ]]; then
    ok "synthetic INFRA-1986 reproduction → alarm fired with hook_silent_passthrough"
else
    fail "synthetic reproduction should emit (events=$EVT, ambient=$(cat "$TMP/ambient.jsonl" 2>/dev/null))"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
