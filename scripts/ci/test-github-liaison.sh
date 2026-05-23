#!/usr/bin/env bash
# test-github-liaison.sh — INFRA-1317
#
# Validates the GitHub Liaison election + heartbeat protocol from
# scripts/ops/github-liaison.sh. Hermetic: no real GitHub API calls, no
# launchd, isolated lockdir + ambient log.
#
# Tests:
#   1. --once on a fresh lockdir acquires the lock and emits liaison_elected.
#   2. Second concurrent --once detects existing fresh liaison and exits 0
#      WITHOUT emitting a second liaison_elected event.
#   3. Stale heartbeat (older than CHUMP_LIAISON_STALE_S) triggers takeover,
#      emitting liaison_takeover.
#   4. Refresh cycle renews the heartbeat file and emits liaison_heartbeat.
#   5. --release removes the lockdir and emits liaison_yielded.
#   6. --check returns 0 for a fresh lock, 1 when no lock exists.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIAISON="$REPO_ROOT/scripts/ops/github-liaison.sh"

PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d -t test-liaison.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

LOCK_DIR="$TMP/github-liaison.lock"
AMBIENT_LOG="$TMP/ambient.jsonl"
# Reconcile script: stub it out — we don't want to hit GitHub from CI. We
# create an empty marker script that exits 0 and let the daemon proceed.
STUB_RECONCILE="$TMP/stub-reconcile.sh"
cat >"$STUB_RECONCILE" <<'STUBEOF'
#!/usr/bin/env bash
# CI stub for github-cache-reconcile.sh — exits 0 without touching GitHub.
echo "stub-reconcile: ok" >&2
exit 0
STUBEOF
chmod +x "$STUB_RECONCILE"

# We can't easily override the reconcile path through env (the daemon hard-codes
# $REPO/scripts/ops/github-cache-reconcile.sh). The reconcile script itself
# tolerates missing `gh` and short-circuits on empty PRS_JSON, so it's safe.
# But for fully hermetic tests we instead monkey-patch by shadowing PATH:
# we don't need to — the daemon swallows reconcile errors (rc=ignored, only
# emits reconcile_ok=0 in the heartbeat).

export CHUMP_LIAISON_LOCK_DIR="$LOCK_DIR"
export CHUMP_AMBIENT_LOG="$AMBIENT_LOG"
export CHUMP_LIAISON_POLL_INTERVAL_S=1
# STALE_S is intentionally larger than test wall-clock so Test 5's --check
# call after Tests 1-4 still sees the heartbeat as fresh. Test 3 backdates
# the heartbeat by 30s to exceed this threshold deterministically.
export CHUMP_LIAISON_STALE_S=20

# A stub `gh` on PATH so the underlying reconcile script (if it gets called)
# doesn't actually hit the network.
BIN_STUB="$TMP/bin"
mkdir -p "$BIN_STUB"
cat >"$BIN_STUB/gh" <<'GHEOF'
#!/usr/bin/env bash
# Test stub — no-op. Echo empty JSON for any read; success exit for writes.
case "${1:-}" in
    repo) [[ "${2:-}" == "view" ]] && { echo '{"nameWithOwner":"test/repo"}'; exit 0; } ;;
    api)  echo '[]'; exit 0 ;;
esac
exit 0
GHEOF
chmod +x "$BIN_STUB/gh"
export PATH="$BIN_STUB:$PATH"

# ── Test 1: fresh election ───────────────────────────────────────────────────
echo "Test 1: fresh election via --once"
: > "$AMBIENT_LOG"
rm -rf "$LOCK_DIR"
if "$LIAISON" --once >/tmp/liaison-t1.out 2>&1; then
    ok "--once exit 0 on fresh lock"
else
    fail "--once failed on fresh lock (see /tmp/liaison-t1.out)"
fi
if [[ -d "$LOCK_DIR" ]]; then
    ok "lockdir created"
else
    fail "lockdir missing after --once"
fi
if grep -q '"kind":"liaison_elected"' "$AMBIENT_LOG"; then
    ok "liaison_elected event emitted"
else
    fail "liaison_elected event missing"
fi
if grep -q '"kind":"liaison_heartbeat"' "$AMBIENT_LOG"; then
    ok "liaison_heartbeat event emitted in first cycle"
else
    fail "liaison_heartbeat event missing"
fi

# ── Test 2: second invocation stands down ────────────────────────────────────
echo "Test 2: second concurrent invocation stands down"
# Lockdir still exists from Test 1. Refresh heartbeat to ensure it's fresh.
date -u +%Y-%m-%dT%H:%M:%SZ > "$LOCK_DIR/heartbeat"
: > "$AMBIENT_LOG"  # clear so we can prove no liaison_elected fires
if "$LIAISON" --once >/tmp/liaison-t2.out 2>&1; then
    ok "second --once exit 0"
else
    fail "second --once non-zero exit (should stand down cleanly)"
fi
if grep -q '"kind":"liaison_elected"' "$AMBIENT_LOG"; then
    fail "liaison_elected fired on second invocation (should NOT)"
else
    ok "no liaison_elected event on second invocation (correctly stood down)"
fi

# ── Test 3: stale heartbeat triggers takeover ────────────────────────────────
echo "Test 3: stale heartbeat triggers takeover"
: > "$AMBIENT_LOG"
# Backdate the heartbeat by 10s (CHUMP_LIAISON_STALE_S=3, so this is stale).
# `touch -t YYYYMMDDhhmm.ss` is *local* time; the daemon reads mtime via
# stat which is timezone-agnostic (epoch seconds), so use local-time date
# arithmetic here.
if [[ "$(uname)" == "Darwin" ]]; then
    BACKDATE="$(date -v-30S +%Y%m%d%H%M.%S)"
else
    BACKDATE="$(date -d '30 seconds ago' +%Y%m%d%H%M.%S)"
fi
touch -t "$BACKDATE" "$LOCK_DIR/heartbeat"
# Also overwrite the holder so we can verify the prev_holder field in the event.
echo "stalehost:99999" > "$LOCK_DIR/holder"

if "$LIAISON" --once >/tmp/liaison-t3.out 2>&1; then
    ok "--once exit 0 on stale lock"
else
    fail "--once failed on stale lock (see /tmp/liaison-t3.out)"
fi
if grep -q '"kind":"liaison_takeover"' "$AMBIENT_LOG"; then
    ok "liaison_takeover event emitted"
else
    fail "liaison_takeover event missing"
fi
if grep -q '"prev_holder":"stalehost:99999"' "$AMBIENT_LOG"; then
    ok "liaison_takeover recorded prev_holder"
else
    fail "liaison_takeover prev_holder not recorded"
fi

# ── Test 4: heartbeat is renewed by refresh cycle ────────────────────────────
echo "Test 4: refresh cycle renews heartbeat mtime"
# We just ran --once in Test 3; heartbeat should be fresh (<3s old).
if [[ -f "$LOCK_DIR/heartbeat" ]]; then
    if [[ "$(uname)" == "Darwin" ]]; then
        AGE=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR/heartbeat") ))
    else
        AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_DIR/heartbeat") ))
    fi
    # Allow up to STALE_S because the refresh cycle calls the real reconcile
    # script which can take a few seconds even with the stub `gh` on PATH.
    # The point is the heartbeat is *fresh* relative to the staleness threshold.
    if [[ "$AGE" -le "$CHUMP_LIAISON_STALE_S" ]]; then
        ok "heartbeat renewed within ${AGE}s of refresh cycle (under ${CHUMP_LIAISON_STALE_S}s threshold)"
    else
        fail "heartbeat age ${AGE}s exceeds stale threshold ${CHUMP_LIAISON_STALE_S}s after cycle"
    fi
else
    fail "heartbeat file missing after refresh"
fi

# ── Test 5: --check returns 0 for fresh lock, 1 when removed ────────────────
echo "Test 5: --check exit codes"
if "$LIAISON" --check >/tmp/liaison-t5a.out 2>&1; then
    ok "--check exit 0 with fresh lock present"
else
    fail "--check returned non-zero with fresh lock (see /tmp/liaison-t5a.out)"
fi
rm -rf "$LOCK_DIR"
if "$LIAISON" --check >/tmp/liaison-t5b.out 2>&1; then
    fail "--check exit 0 with no lock (should be 1)"
else
    ok "--check exit 1 when lockdir absent"
fi

# ── Test 6: --release removes lockdir and emits liaison_yielded ─────────────
echo "Test 6: --release"
: > "$AMBIENT_LOG"
"$LIAISON" --once >/dev/null 2>&1  # re-acquire
if [[ ! -d "$LOCK_DIR" ]]; then
    fail "could not re-acquire lock for release test"
else
    if "$LIAISON" --release >/tmp/liaison-t6.out 2>&1; then
        ok "--release exit 0"
    else
        fail "--release non-zero exit"
    fi
    if [[ ! -d "$LOCK_DIR" ]]; then
        ok "lockdir removed by --release"
    else
        fail "lockdir still present after --release"
    fi
    if grep -q '"kind":"liaison_yielded"' "$AMBIENT_LOG"; then
        ok "liaison_yielded event emitted"
    else
        fail "liaison_yielded event missing"
    fi
fi

# ── Test 7: daemon mode requires opt-in ──────────────────────────────────────
echo "Test 7: daemon mode requires CHUMP_LIAISON_ENABLED=1"
# The daemon refuses to start without CHUMP_LIAISON_ENABLED=1 and exits
# immediately with rc=2. Run synchronously (no background fork) so we
# observe the deterministic exit code, not a race with `kill -0`.
RC=0
env -u CHUMP_LIAISON_ENABLED "$LIAISON" >/tmp/liaison-t7.out 2>&1 || RC=$?
if [[ "$RC" -eq 2 ]]; then
    ok "daemon mode refused without opt-in (exit 2)"
else
    fail "daemon mode exited $RC (expected 2) without opt-in (output: $(cat /tmp/liaison-t7.out))"
fi

# ── summary ──────────────────────────────────────────────────────────────────
echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
