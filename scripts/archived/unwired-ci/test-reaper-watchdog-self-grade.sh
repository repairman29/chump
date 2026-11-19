#!/usr/bin/env bash
# test-reaper-watchdog-self-grade.sh — INFRA-452
#
# Verifies two complementary blind-spot fixes:
#   1. The watchdog's own default TARGETS list now includes "watchdog" so it
#      grades its own previous heartbeat (the gap title's canary-died case).
#   2. reaper_grade_watchdog (called from reaper_finish) cross-grades the
#      watchdog from every other reaper, so even if the watchdog is dead-
#      forever, the next reaper run emits the ALERT.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
WATCHDOG="$REPO_ROOT/scripts/ops/reaper-heartbeat-watchdog.sh"
INSTRUM="$REPO_ROOT/scripts/lib/reaper-instrumentation.sh"

[[ -f "$WATCHDOG" ]] || { echo "FATAL: watchdog not found"; exit 2; }
[[ -f "$INSTRUM" ]]  || { echo "FATAL: instrumentation not found"; exit 2; }

echo "=== INFRA-452 reaper-watchdog self-grade test ==="
echo

# --- Test 1: watchdog includes 'watchdog' in its default TARGETS ---
if grep -qE 'TARGETS=\(.*watchdog.*\)' "$WATCHDOG"; then
    ok "watchdog default TARGETS includes 'watchdog' (self-grade)"
else
    fail "watchdog default TARGETS missing 'watchdog' — self-grade not wired"
fi

# --- Test 2: watchdog has a threshold case for 'watchdog' ---
if grep -qE 'watchdog\)[[:space:]]+echo' "$WATCHDOG"; then
    ok "watchdog threshold_secs has explicit case for 'watchdog'"
else
    fail "watchdog threshold_secs missing 'watchdog' case"
fi

# --- Test 3: reaper_grade_watchdog exists and is called from reaper_finish ---
if grep -q 'reaper_grade_watchdog()' "$INSTRUM" \
   && grep -A 12 '^reaper_finish()' "$INSTRUM" | grep -q 'reaper_grade_watchdog'; then
    ok "reaper_grade_watchdog defined and called from reaper_finish"
else
    fail "reaper_grade_watchdog missing or not called from reaper_finish"
fi

# --- Test 4: cross-grade emits an ALERT when watchdog is stale (live test) ---
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Sandbox: separate ambient.jsonl and a fake heartbeat file.
SANDBOX_LOCK_DIR="$TMPDIR_BASE/locks"
mkdir -p "$SANDBOX_LOCK_DIR"
SANDBOX_AMBIENT="$SANDBOX_LOCK_DIR/ambient.jsonl"
FAKE_HB="/tmp/chump-reaper-watchdog.heartbeat.test-$$"

# Pre-stage a stale heartbeat (3h ago).
ANCIENT_TS=$(date -u -r $(($(date +%s) - 3*3600)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
          || date -u -d "@$(($(date +%s) - 3*3600))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
          || date -u +%Y-%m-%dT%H:%M:%SZ)
cat >"$FAKE_HB" <<EOF
ts=$ANCIENT_TS
status=ok
duration=1
counts={}
EOF
# Backdate mtime as well, in case ts parsing falls back to mtime.
touch -t "$(date -r $(($(date +%s) - 3*3600)) +%Y%m%d%H%M.%S 2>/dev/null \
       || date -d "@$(($(date +%s) - 3*3600))" +%Y%m%d%H%M.%S 2>/dev/null \
       || date +%Y%m%d%H%M.%S)" "$FAKE_HB" 2>/dev/null || true

# Source instrumentation in a subshell, point it at the sandbox + fake HB,
# and call reaper_grade_watchdog with REAPER_NAME=pr.
GRADE_OUT=$(
    set -e
    # shellcheck disable=SC1090
    source "$INSTRUM"
    REAPER_NAME=pr
    REAPER_LOCK_DIR="$SANDBOX_LOCK_DIR"
    # Override the heartbeat path inside the function. Easiest: shadow with
    # a wrapper that swaps the path before delegating. Or just symlink the
    # real path. We use a temp override: copy the function and patch the
    # /tmp/chump-reaper-watchdog.heartbeat literal.
    eval "$(declare -f reaper_grade_watchdog | sed "s|/tmp/chump-reaper-watchdog.heartbeat|$FAKE_HB|")"
    reaper_grade_watchdog 2>&1
)

if grep -qE '"kind":[[:space:]]*"watchdog_silent"' "$SANDBOX_AMBIENT" 2>/dev/null; then
    ok "cross-grade emitted watchdog_silent ALERT to ambient.jsonl"
else
    fail "cross-grade did NOT emit watchdog_silent ALERT (ambient: $(cat "$SANDBOX_AMBIENT" 2>/dev/null || echo none))"
fi

# --- Test 5: cross-grade is silent when watchdog is fresh ---
FRESH_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat >"$FAKE_HB" <<EOF
ts=$FRESH_TS
status=ok
duration=1
counts={}
EOF
: > "$SANDBOX_AMBIENT"

(
    set -e
    # shellcheck disable=SC1090
    source "$INSTRUM"
    REAPER_NAME=pr
    REAPER_LOCK_DIR="$SANDBOX_LOCK_DIR"
    eval "$(declare -f reaper_grade_watchdog | sed "s|/tmp/chump-reaper-watchdog.heartbeat|$FAKE_HB|")"
    reaper_grade_watchdog 2>/dev/null || true
)

if [[ ! -s "$SANDBOX_AMBIENT" ]] || ! grep -q '"watchdog_silent"' "$SANDBOX_AMBIENT"; then
    ok "cross-grade silent when watchdog heartbeat is fresh"
else
    fail "cross-grade falsely alerted on fresh heartbeat"
fi

# --- Test 6: cross-grade self-suppresses when REAPER_NAME=watchdog ---
: > "$SANDBOX_AMBIENT"
# Stale again
cat >"$FAKE_HB" <<EOF
ts=$ANCIENT_TS
status=ok
duration=1
counts={}
EOF

(
    set -e
    # shellcheck disable=SC1090
    source "$INSTRUM"
    REAPER_NAME=watchdog
    REAPER_LOCK_DIR="$SANDBOX_LOCK_DIR"
    eval "$(declare -f reaper_grade_watchdog | sed "s|/tmp/chump-reaper-watchdog.heartbeat|$FAKE_HB|")"
    reaper_grade_watchdog 2>/dev/null || true
)

if [[ ! -s "$SANDBOX_AMBIENT" ]] || ! grep -q '"watchdog_silent"' "$SANDBOX_AMBIENT"; then
    ok "cross-grade self-suppresses when called from watchdog itself"
else
    fail "cross-grade fired when REAPER_NAME=watchdog (should self-suppress)"
fi

rm -f "$FAKE_HB"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
