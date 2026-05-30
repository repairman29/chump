#!/usr/bin/env bash
# test-ci-audit-loop.sh — INFRA-1923: smoke test for scripts/coord/ci-audit-loop.sh.
#
# Exercises each subcommand on a synthetic happy path and asserts the
# documented exit codes (0 = success, 1 = quiet, 2 = bad input, 3 = missing
# state). Plus asserts ambient emissions land in CHUMP_AMBIENT_LOG with
# the right kind tags (ci_audit_heartbeat, ci_cluster_detected).

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
LOOP_SCRIPT="$REPO_ROOT/scripts/coord/ci-audit-loop.sh"

if [[ ! -f "$LOOP_SCRIPT" ]]; then
    echo "FAIL: $LOOP_SCRIPT not found" >&2
    exit 1
fi

# Ensure the script is executable
chmod +x "$LOOP_SCRIPT"

_pass=0
_fail=0

_ok()  { echo "  ✓ $*"; _pass=$((_pass + 1)); }
_bad() { echo "  ✗ FAIL: $*" >&2; _fail=$((_fail + 1)); }

# ── Test 1: bash -n syntax check ──────────────────────────────────────────
echo "Test 1: bash -n syntax check..."
if bash -n "$LOOP_SCRIPT" 2>/dev/null; then
    _ok "bash -n passes (no syntax errors)"
else
    _bad "bash -n failed — syntax error in ci-audit-loop.sh"
fi

# ── Test 2: help exits 0 ───────────────────────────────────────────────────
echo "Test 2: help subcommand..."
_rc=0
"$LOOP_SCRIPT" help >/dev/null 2>&1 || _rc=$?
if (( _rc == 0 )); then
    _ok "help exits 0"
else
    _bad "help should exit 0, got $_rc"
fi

# Also test --help and -h aliases
_rc=0
"$LOOP_SCRIPT" --help >/dev/null 2>&1 || _rc=$?
if (( _rc == 0 )); then
    _ok "--help exits 0"
else
    _bad "--help should exit 0, got $_rc"
fi

# ── Test 3: heartbeat emits ci_audit_heartbeat ─────────────────────────────
echo "Test 3: heartbeat subcommand..."
_dir3="$(mktemp -d)"
_amb3="$_dir3/ambient.jsonl"
_rc=0
CHUMP_AMBIENT_LOG="$_amb3" \
CHUMP_SESSION_ID="test-ci-audit-heartbeat" \
"$LOOP_SCRIPT" heartbeat >/dev/null 2>&1 || _rc=$?

if (( _rc == 0 )); then
    _ok "heartbeat exits 0"
else
    _bad "heartbeat should exit 0, got $_rc"
fi

if grep -q '"kind":"ci_audit_heartbeat"' "$_amb3" 2>/dev/null; then
    _ok "heartbeat emits ci_audit_heartbeat kind"
else
    _bad "heartbeat did not emit ci_audit_heartbeat to ambient"
fi

if grep -q '"session":"test-ci-audit-heartbeat"' "$_amb3" 2>/dev/null; then
    _ok "heartbeat preserves CHUMP_SESSION_ID in emit"
else
    _bad "heartbeat did not pick up CHUMP_SESSION_ID"
fi

if grep -q '"role":"ci-audit"' "$_amb3" 2>/dev/null; then
    _ok "heartbeat includes role field"
else
    _bad "heartbeat missing role field in emit"
fi
rm -rf "$_dir3"

# ── Test 4: tick exits 0 or 1 (quiet or actionable) ───────────────────────
echo "Test 4: tick subcommand..."
_dir4="$(mktemp -d)"
_amb4="$_dir4/ambient.jsonl"
_rc=0
CHUMP_AMBIENT_LOG="$_amb4" \
CHUMP_SESSION_ID="test-ci-audit-tick" \
"$LOOP_SCRIPT" tick >/dev/null 2>&1 || _rc=$?

# tick exits 0 (actionable) or 1 (quiet) — both are valid
if (( _rc == 0 || _rc == 1 )); then
    _ok "tick exits 0 (actionable) or 1 (quiet); got $_rc"
else
    _bad "tick should exit 0 or 1, got $_rc"
fi

_tick_out="$(CHUMP_AMBIENT_LOG="$_amb4" CHUMP_SESSION_ID="test-ci-audit-tick" \
    "$LOOP_SCRIPT" tick 2>&1 || true)"
if echo "$_tick_out" | grep -q "curator-opus-ci-audit tick"; then
    _ok "tick prints curator header"
else
    _bad "tick missing curator header"
fi
if echo "$_tick_out" | grep -q "Inbox"; then
    _ok "tick prints inbox section"
else
    _bad "tick missing inbox section"
fi
if echo "$_tick_out" | grep -q "Ambient CI events"; then
    _ok "tick prints ambient CI events section"
else
    _bad "tick missing ambient CI events section"
fi
rm -rf "$_dir4"

# ── Test 5: audit exits 0 or 1 with synthetic ambient ─────────────────────
echo "Test 5: audit subcommand (quiet ambient)..."
_dir5="$(mktemp -d)"
_amb5="$_dir5/ambient.jsonl"
# Start with an empty ambient — audit should exit 1 (quiet)
touch "$_amb5"
_rc=0
CHUMP_AMBIENT_LOG="$_amb5" \
CHUMP_SESSION_ID="test-ci-audit-audit-quiet" \
"$LOOP_SCRIPT" audit >/dev/null 2>&1 || _rc=$?

if (( _rc == 0 || _rc == 1 )); then
    _ok "audit exits 0 or 1 on empty ambient; got $_rc"
else
    _bad "audit should exit 0 or 1 on empty ambient, got $_rc"
fi

echo "Test 5b: audit subcommand (synthetic pr_stuck ambient)..."
# Inject a synthetic pr_stuck event
printf '{"ts":"2026-05-25T00:00:00Z","kind":"pr_stuck","pr":9999}\n' >> "$_amb5"
_rc=0
CHUMP_AMBIENT_LOG="$_amb5" \
CHUMP_SESSION_ID="test-ci-audit-audit-active" \
"$LOOP_SCRIPT" audit >/dev/null 2>&1 || _rc=$?

if (( _rc == 0 )); then
    _ok "audit exits 0 when pr_stuck event present"
else
    _bad "audit should exit 0 when pr_stuck found, got $_rc"
fi

if grep -q '"kind":"ci_cluster_detected"' "$_amb5" 2>/dev/null; then
    _ok "audit emits ci_cluster_detected when cluster found"
else
    _bad "audit did not emit ci_cluster_detected"
fi
rm -rf "$_dir5"

# ── Test 5c: audit picks up regression_attributed (CREDIBLE-079) ──────────
echo "Test 5c: audit subcommand (synthetic regression_attributed ambient)..."
_dir5c="$(mktemp -d)"
_amb5c="$_dir5c/ambient.jsonl"
# Three regression_attributed events fingering the same suspect_commits
for i in 1 2 3; do
    printf '{"ts":"2026-05-30T04:0%d:00Z","kind":"regression_attributed","source":"blame_bot","green_sha":"9b8dd5bf8994","suspect_commits":"3d02c15b3,f1c748788","checks_attributed":"test,audit","count":2}\n' "$i" >> "$_amb5c"
done

_rc=0
CHUMP_AMBIENT_LOG="$_amb5c" \
CHUMP_SESSION_ID="test-ci-audit-regression" \
"$LOOP_SCRIPT" audit >/dev/null 2>&1 || _rc=$?

if (( _rc == 0 )); then
    _ok "audit exits 0 when regression_attributed event present"
else
    _bad "audit should exit 0 when regression_attributed found, got $_rc"
fi

# Capture stdout to assert bucket header + suspect surfacing
_audit_out="$(CHUMP_AMBIENT_LOG="$_amb5c" CHUMP_SESSION_ID="test-ci-audit-regression" \
    "$LOOP_SCRIPT" audit 2>&1 || true)"

if echo "$_audit_out" | grep -q "regression_attributed events"; then
    _ok "audit prints regression_attributed bucket header"
else
    _bad "audit missing regression_attributed bucket header"
fi

if echo "$_audit_out" | grep -q "blame-bot regression cluster"; then
    _ok "audit labels bucket as blame-bot regression cluster"
else
    _bad "audit missing blame-bot cluster label"
fi

if echo "$_audit_out" | grep -q "suspect_commits: 3d02c15b3,f1c748788"; then
    _ok "audit surfaces suspect_commits from event"
else
    _bad "audit did not surface suspect_commits"
fi

if echo "$_audit_out" | grep -q "checks_attributed: test,audit"; then
    _ok "audit surfaces checks_attributed from event"
else
    _bad "audit did not surface checks_attributed"
fi

# ci_cluster_detected must still emit even when only the new bucket fires
if grep -q '"kind":"ci_cluster_detected"' "$_amb5c" 2>/dev/null; then
    _ok "audit emits ci_cluster_detected for regression_attributed cluster"
else
    _bad "audit did not emit ci_cluster_detected for regression_attributed"
fi

rm -rf "$_dir5c"

# ── Test 6: audit exits 3 when ambient missing ────────────────────────────
echo "Test 6: audit exits 3 when ambient missing..."
_rc=0
CHUMP_AMBIENT_LOG="/tmp/nonexistent-ambient-ci-audit-test-$$" \
CHUMP_SESSION_ID="test-ci-audit-no-ambient" \
"$LOOP_SCRIPT" audit >/dev/null 2>&1 || _rc=$?
if (( _rc == 3 )); then
    _ok "audit exits 3 when ambient log missing"
else
    _bad "audit should exit 3 on missing ambient, got $_rc"
fi

# ── Test 7: unknown subcommand exits 2 ────────────────────────────────────
echo "Test 7: unknown subcommand..."
_rc=0
"$LOOP_SCRIPT" not-a-real-subcommand >/dev/null 2>&1 || _rc=$?
if (( _rc == 2 )); then
    _ok "unknown subcommand exits 2"
else
    _bad "unknown subcommand should exit 2, got $_rc"
fi

# ── Test 8: all 4 subcommands recognized (not exit 2) ─────────────────────
echo "Test 8: all subcommands recognized..."
_dir8="$(mktemp -d)"
_amb8="$_dir8/ambient.jsonl"
touch "$_amb8"

for sub in tick audit heartbeat help; do
    _rc=0
    CHUMP_AMBIENT_LOG="$_amb8" \
    CHUMP_SESSION_ID="test-ci-audit-subcmd-check" \
    "$LOOP_SCRIPT" "$sub" >/dev/null 2>&1 || _rc=$?
    if (( _rc != 2 )); then
        _ok "subcommand '$sub' recognized (exit $_rc, not 2)"
    else
        _bad "subcommand '$sub' returned exit 2 (unrecognized)"
    fi
done
rm -rf "$_dir8"

# ── Test 9: scanner-anchor discipline (AC from handoff pattern) ───────────
echo "Test 9: scanner-anchor comments present in source..."
if grep -q '# scanner-anchor: "kind":"ci_audit_heartbeat"' "$LOOP_SCRIPT"; then
    _ok "ci_audit_heartbeat has scanner-anchor comment"
else
    _bad "ci_audit_heartbeat missing scanner-anchor comment"
fi
if grep -q '# scanner-anchor: "kind":"ci_cluster_detected"' "$LOOP_SCRIPT"; then
    _ok "ci_cluster_detected has scanner-anchor comment"
else
    _bad "ci_cluster_detected missing scanner-anchor comment"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo
echo "Results: ${_pass} passed, ${_fail} failed"
if (( _fail > 0 )); then
    exit 1
fi
echo "✓ All ci-audit-loop tests passed"
