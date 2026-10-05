#!/usr/bin/env bash
# test-farmer-stale-lease-heartbeat.sh — RESILIENT-313
#
# Regression guard for the silent fleet-stall root cause: a present/stale
# claim-*.json lease used to CRASH the farmer tick BEFORE it wrote the heartbeat
# the worker binary gates on, darking out every worker on the host.
#
# The crash was Linux-specific: scripts/coord/farmer.sh used a macOS-first
# `stat -f %m F || stat -c %Y F`. On GNU/Linux `stat -f` means --file-system and
# `%m` is a second path arg, so stat prints a multi-line filesystem block to
# stdout AND exits non-zero; the `||` fallback then CONCATENATES its output onto
# that garbage. `$(( now - mtime ))` on the garbage tripped `set -u` on the token
# `File` → the tick died before write_heartbeat.
#
# DELIBERATELY RUNS ON LINUX (unlike test-farmer.sh, which SKIPs non-Darwin and
# therefore never caught this). The whole point is the Linux code path.
#
# Asserts, with a synthetic stale lease present:
#   1. the tick exits 0 (no crash),
#   2. no "unbound variable" in output,
#   3. the in-repo heartbeat file is written fresh,
#   4. the durable out-of-repo ($HOME/.chump) heartbeat is written fresh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FARMER="$REPO_ROOT/scripts/coord/farmer.sh"

[[ -f "$FARMER" ]] || { echo "FAIL: farmer.sh not found: $FARMER"; exit 1; }

PASS=0; FAIL=0
_pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAKE_REPO="$WORK/repo"
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_REPO/.chump-locks" "$FAKE_REPO/.chump" "$FAKE_HOME/.chump"

# Synthetic stale lease with an mtime ~1h in the past. GNU `touch -d @epoch`
# first, BSD `touch -t` fallback, so the fixture is portable.
LEASE="$FAKE_REPO/.chump-locks/claim-STALE-test.json"
printf '{"gap":"STALE-test","agent":"fleet-1","session_id":"stale-sess","ts":"2026-01-01T00:00:00Z"}\n' > "$LEASE"
OLD_EPOCH=$(( $(date +%s) - 3700 ))
if ! touch -d "@${OLD_EPOCH}" "$LEASE" 2>/dev/null; then
    touch -t "$(date -r "$OLD_EPOCH" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@${OLD_EPOCH}" +%Y%m%d%H%M.%S)" "$LEASE" 2>/dev/null || true
fi

IN_REPO_HB="$FAKE_REPO/.chump/farmer-heartbeat"
DURABLE_HB="$FAKE_HOME/.chump/farmer-heartbeat"
rm -f "$IN_REPO_HB" "$DURABLE_HB"

echo "T1: farmer tick with a stale lease present must NOT crash and MUST write the heartbeat"
# FARMER_SILENT_WORKER_S=0 forces the stale-lease code path (the historical crash
# site) to execute for ANY lease, so the guard is exercised deterministically.
set +e
OUT="$(HOME="$FAKE_HOME" CHUMP_REPO_ROOT="$FAKE_REPO" FARMER_DRY_RUN=1 \
       FARMER_SILENT_WORKER_S=0 bash "$FARMER" 2>&1)"
RC=$?
set -e 2>/dev/null || true
echo "$OUT" | sed 's/^/    farmer| /'
echo "    (exit=$RC)"

[[ "$RC" -eq 0 ]] && _pass "tick exited 0 (no crash)" || _fail "tick exited $RC (expected 0 — the crash regression)"
if echo "$OUT" | grep -qi "unbound variable"; then
    _fail "output contains 'unbound variable' (the RESILIENT-313 crash)"
else
    _pass "no 'unbound variable' in output"
fi
[[ -f "$IN_REPO_HB" ]] && _pass "in-repo heartbeat written ($IN_REPO_HB)" || _fail "in-repo heartbeat NOT written"
[[ -f "$DURABLE_HB" ]] && _pass "durable out-of-repo heartbeat written ($DURABLE_HB)" || _fail "durable heartbeat NOT written"

# Freshness: the heartbeat must be recent (< 120s, the worker-gate threshold).
if [[ -f "$IN_REPO_HB" ]]; then
    HB_M="$(stat -c %Y "$IN_REPO_HB" 2>/dev/null || stat -f %m "$IN_REPO_HB" 2>/dev/null || echo 0)"
    HB_AGE=$(( $(date +%s) - HB_M ))
    [[ "$HB_AGE" -lt 120 ]] && _pass "heartbeat is fresh (age=${HB_AGE}s < 120s)" || _fail "heartbeat stale (age=${HB_AGE}s)"
fi

echo
echo "T2: control — a tick with NO leases at all also writes the heartbeat"
rm -f "$IN_REPO_HB" "$DURABLE_HB" "$LEASE"
set +e
HOME="$FAKE_HOME" CHUMP_REPO_ROOT="$FAKE_REPO" FARMER_DRY_RUN=1 bash "$FARMER" >/dev/null 2>&1
RC2=$?
set -e 2>/dev/null || true
[[ "$RC2" -eq 0 && -f "$IN_REPO_HB" ]] && _pass "no-lease tick wrote heartbeat (exit=$RC2)" || _fail "no-lease tick failed (exit=$RC2)"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: RESILIENT-313 stale-lease heartbeat regression guard passing"
