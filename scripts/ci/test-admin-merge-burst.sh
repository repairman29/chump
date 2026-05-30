#!/usr/bin/env bash
# scripts/ci/test-admin-merge-burst.sh — INFRA-2071 smoke test
#
# Tests the admin-merge-cycle.sh burst circuit-breaker:
#   Test 1: burst trips when count >= threshold (noise-class path, NOT --force-admin)
#   Test 2: CHUMP_ADMIN_MERGE_FORCE=1 overrides trip → emits burst_overridden, exits 0
#   Test 3: below-threshold count → no burst → normal validation path (exits 1 on snapshot missing)
#   Test 4: custom threshold env var respected
#   Test 5: custom window env var respected (old events outside window don't count)
#   Test 6: _count_recent_runs returns 0 on missing ambient log
#   Test 7: admin_merge_cycle_run emitted per successful merge (counted by burst)
#   Test 8: --force-admin also overrides burst (emits burst_overridden)

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/ops/admin-merge-cycle.sh"
PASS=0
FAIL=0

_pass() { echo "  PASS: $1"; (( PASS++ )) || true; }
_fail() { echo "  FAIL: $1"; (( FAIL++ )) || true; }

_check() {
    local label="$1"; shift
    if "$@" 2>/dev/null; then
        _pass "$label"
    else
        _fail "$label (exit $?)"
    fi
}

_check_exit() {
    local label="$1"
    local expected="$2"; shift 2
    local actual
    actual=0
    "$@" 2>/dev/null || actual=$?
    if [[ "$actual" -eq "$expected" ]]; then
        _pass "$label (exit=$actual)"
    else
        _fail "$label (expected exit=$expected, got exit=$actual)"
    fi
}

# ── Setup shared tmpdir ────────────────────────────────────────────────────────

TMPDIR_ROOT="$(mktemp -d /tmp/test-admin-merge-burst.XXXXXX)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Ruleset snapshot stubs (required by script after burst check passes)
SNAPSHOT_DIR="$TMPDIR_ROOT/ruleset-snapshots"
mkdir -p "$SNAPSHOT_DIR"
echo '{}' > "$SNAPSHOT_DIR/drop.json"
echo '{}' > "$SNAPSHOT_DIR/restore.json"

# Noise-classes YAML with a test class whose matches entry covers our mock check
NOISE_CLASSES="$TMPDIR_ROOT/noise-classes.yaml"
cat > "$NOISE_CLASSES" <<'YAML'
classes:
  - id: test-burst-class
    description: "Fake noise class for burst circuit-breaker test"
    matches:
      - "my-fake-failing-check"
    upstream_fix_gap: ""
    expires_after_ship: false
YAML

# Mock-gh: responds to "gh pr checks <N>" with one failing check line,
# and swallows all other gh calls (repo view, api PUT, pr merge) silently.
MOCK_GH="$TMPDIR_ROOT/mock-gh"
cat > "$MOCK_GH" <<'SH'
#!/usr/bin/env bash
# Minimal mock-gh for burst test
if [[ "${1:-}" == "pr" && "${2:-}" == "checks" ]]; then
    # Emit one failing check so noise-class validator finds a match
    printf 'my-fake-failing-check\tfail\t1s\thttps://example.invalid/job/1\n'
    exit 0
fi
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
    echo '{"nameWithOwner":"test-owner/test-repo"}'
    exit 0
fi
# api PUT, pr merge, etc. — silently succeed
exit 0
SH
chmod +x "$MOCK_GH"

# Helper: build an ambient.jsonl with N admin_merge_cycle_run events timestamped
# within the last 60 seconds (well inside the default 3600s window).
_make_ambient() {
    local path="$1"
    local count="$2"
    local age_s="${3:-30}"   # seconds ago per event
    > "$path"
    for (( i=0; i<count; i++ )); do
        local ts
        ts="$(python3 -c "
from datetime import datetime, timezone, timedelta
import sys
now = datetime.now(timezone.utc) - timedelta(seconds=$age_s)
print(now.strftime('%Y-%m-%dT%H:%M:%SZ'))
")"
        printf '{"ts":"%s","kind":"admin_merge_cycle_run","source":"admin_merge_cycle","pr":"99","reason":"noise-class: test-burst-class","operator_session_id":"test"}\n' \
            "$ts" >> "$path"
    done
}

# Common env for all tests
BASE_ENV=(
    env
    CHUMP_NOISE_CLASSES_FILE="$NOISE_CLASSES"
    CHUMP_ADMIN_MERGE_TEST_GH="$MOCK_GH"
    CHUMP_ADMIN_MERGE_REPO="test-owner/test-repo"
)

echo ""
echo "=== test-admin-merge-burst.sh (INFRA-2071) ==="
echo ""

# ── Test 1: burst trips via noise-class path (NOT --force-admin) ──────────────
echo "Test 1: burst trips when count >= threshold (noise-class path)"
T1_DIR="$TMPDIR_ROOT/t1"
mkdir -p "$T1_DIR/ruleset-snapshots"
cp "$SNAPSHOT_DIR"/*.json "$T1_DIR/ruleset-snapshots/"
T1_AMBIENT="$T1_DIR/ambient.jsonl"
_make_ambient "$T1_AMBIENT" 3   # 3 events = threshold (default 3) → trip

T1_OUT="$("${BASE_ENV[@]}" \
    CHUMP_AMBIENT_LOG="$T1_AMBIENT" \
    CHUMP_ADMIN_MERGE_BURST_THRESHOLD=3 \
    bash "$SCRIPT" \
        --pr 100 \
        --noise-class test-burst-class \
    2>&1 || true)"

T1_EXIT=0
"${BASE_ENV[@]}" \
    CHUMP_AMBIENT_LOG="$T1_AMBIENT" \
    CHUMP_ADMIN_MERGE_BURST_THRESHOLD=3 \
    bash "$SCRIPT" \
        --pr 100 \
        --noise-class test-burst-class \
    2>/dev/null || T1_EXIT=$?

# Should exit 3 (circuit-breaker)
if [[ "$T1_EXIT" -eq 3 ]]; then
    _pass "Test 1a: exits 3 on burst trip"
else
    _fail "Test 1a: expected exit 3, got $T1_EXIT"
fi

# Should emit admin_merge_burst to ambient log
if grep -q '"kind":"admin_merge_burst"' "$T1_AMBIENT" 2>/dev/null; then
    _pass "Test 1b: admin_merge_burst emitted"
else
    _fail "Test 1b: admin_merge_burst NOT found in ambient log"
    echo "  ambient log contents:"
    grep "admin_merge" "$T1_AMBIENT" 2>/dev/null | head -5 || echo "  (empty)"
fi

# Should NOT emit admin_merge_burst_overridden
if ! grep -q '"kind":"admin_merge_burst_overridden"' "$T1_AMBIENT" 2>/dev/null; then
    _pass "Test 1c: no burst_overridden (correct — not an override)"
else
    _fail "Test 1c: burst_overridden was emitted (should not be)"
fi

# burst event should have operator_action_needed=true
if grep '"kind":"admin_merge_burst"' "$T1_AMBIENT" 2>/dev/null | grep -q '"operator_action_needed":true'; then
    _pass "Test 1d: operator_action_needed=true in burst event"
else
    _fail "Test 1d: operator_action_needed=true missing from burst event"
fi

echo ""

# ── Test 2: CHUMP_ADMIN_MERGE_FORCE=1 overrides burst ────────────────────────
echo "Test 2: CHUMP_ADMIN_MERGE_FORCE=1 overrides burst, emits burst_overridden"
T2_DIR="$TMPDIR_ROOT/t2"
mkdir -p "$T2_DIR/ruleset-snapshots"
cp "$SNAPSHOT_DIR"/*.json "$T2_DIR/ruleset-snapshots/"
T2_AMBIENT="$T2_DIR/ambient.jsonl"
_make_ambient "$T2_AMBIENT" 3   # same burst condition

T2_EXIT=0
"${BASE_ENV[@]}" \
    CHUMP_AMBIENT_LOG="$T2_AMBIENT" \
    CHUMP_ADMIN_MERGE_BURST_THRESHOLD=3 \
    CHUMP_ADMIN_MERGE_FORCE=1 \
    bash "$SCRIPT" \
        --pr 101 \
        --noise-class test-burst-class \
    2>/dev/null || T2_EXIT=$?

# Should exit 0 (override succeeds through to merge)
if [[ "$T2_EXIT" -eq 0 ]]; then
    _pass "Test 2a: exits 0 with CHUMP_ADMIN_MERGE_FORCE=1 override"
else
    _fail "Test 2a: expected exit 0, got $T2_EXIT"
fi

# Should emit admin_merge_burst (still emitted before override)
if grep -q '"kind":"admin_merge_burst"' "$T2_AMBIENT" 2>/dev/null; then
    _pass "Test 2b: admin_merge_burst emitted (burst was detected)"
else
    _fail "Test 2b: admin_merge_burst NOT found — burst should be detected before override"
fi

# Should emit admin_merge_burst_overridden
if grep -q '"kind":"admin_merge_burst_overridden"' "$T2_AMBIENT" 2>/dev/null; then
    _pass "Test 2c: admin_merge_burst_overridden emitted"
else
    _fail "Test 2c: admin_merge_burst_overridden NOT found"
fi

# override_method should be CHUMP_ADMIN_MERGE_FORCE
if grep '"kind":"admin_merge_burst_overridden"' "$T2_AMBIENT" 2>/dev/null | grep -q '"override_method":"CHUMP_ADMIN_MERGE_FORCE"'; then
    _pass "Test 2d: override_method=CHUMP_ADMIN_MERGE_FORCE"
else
    _fail "Test 2d: override_method not CHUMP_ADMIN_MERGE_FORCE"
fi

echo ""

# ── Test 3: below threshold → no burst → normal validation ───────────────────
echo "Test 3: below threshold — no burst trip, exits 1 on missing snapshot (not 3)"
T3_DIR="$TMPDIR_ROOT/t3"
mkdir -p "$T3_DIR"
# No ruleset-snapshots dir — script will hit snapshot-missing exit 1 after passing burst
T3_AMBIENT="$T3_DIR/ambient.jsonl"
_make_ambient "$T3_AMBIENT" 2   # 2 events < threshold of 3

T3_EXIT=0
"${BASE_ENV[@]}" \
    CHUMP_AMBIENT_LOG="$T3_AMBIENT" \
    CHUMP_ADMIN_MERGE_BURST_THRESHOLD=3 \
    bash "$SCRIPT" \
        --pr 102 \
        --noise-class test-burst-class \
    2>/dev/null || T3_EXIT=$?

# Should NOT exit 3 (burst not tripped)
if [[ "$T3_EXIT" -ne 3 ]]; then
    _pass "Test 3a: exit is not 3 (burst not tripped at count=2/threshold=3)"
else
    _fail "Test 3a: exit was 3 (burst incorrectly tripped)"
fi

# Should NOT emit admin_merge_burst
if ! grep -q '"kind":"admin_merge_burst"' "$T3_AMBIENT" 2>/dev/null; then
    _pass "Test 3b: no admin_merge_burst (correct — below threshold)"
else
    _fail "Test 3b: admin_merge_burst emitted below threshold"
fi

echo ""

# ── Test 4: custom threshold env var ─────────────────────────────────────────
echo "Test 4: custom CHUMP_ADMIN_MERGE_BURST_THRESHOLD=2 trips at count=2"
T4_DIR="$TMPDIR_ROOT/t4"
mkdir -p "$T4_DIR/ruleset-snapshots"
cp "$SNAPSHOT_DIR"/*.json "$T4_DIR/ruleset-snapshots/"
T4_AMBIENT="$T4_DIR/ambient.jsonl"
_make_ambient "$T4_AMBIENT" 2   # 2 events

T4_EXIT=0
"${BASE_ENV[@]}" \
    CHUMP_AMBIENT_LOG="$T4_AMBIENT" \
    CHUMP_ADMIN_MERGE_BURST_THRESHOLD=2 \
    bash "$SCRIPT" \
        --pr 103 \
        --noise-class test-burst-class \
    2>/dev/null || T4_EXIT=$?

if [[ "$T4_EXIT" -eq 3 ]]; then
    _pass "Test 4: threshold=2 trips at count=2"
else
    _fail "Test 4: expected exit 3, got $T4_EXIT"
fi

echo ""

# ── Test 5: events outside window don't count ─────────────────────────────────
echo "Test 5: events older than CHUMP_ADMIN_MERGE_BURST_WINDOW_S are ignored"
T5_DIR="$TMPDIR_ROOT/t5"
mkdir -p "$T5_DIR/ruleset-snapshots"
cp "$SNAPSHOT_DIR"/*.json "$T5_DIR/ruleset-snapshots/"
T5_AMBIENT="$T5_DIR/ambient.jsonl"
# 3 events but 2 hours old, window=60s → should not count
_make_ambient "$T5_AMBIENT" 3 7200   # 7200s = 2 hours ago

T5_EXIT=0
"${BASE_ENV[@]}" \
    CHUMP_AMBIENT_LOG="$T5_AMBIENT" \
    CHUMP_ADMIN_MERGE_BURST_THRESHOLD=3 \
    CHUMP_ADMIN_MERGE_BURST_WINDOW_S=60 \
    bash "$SCRIPT" \
        --pr 104 \
        --noise-class test-burst-class \
    2>/dev/null || T5_EXIT=$?

# Should not trip (old events outside 60s window)
if [[ "$T5_EXIT" -ne 3 ]]; then
    _pass "Test 5: old events outside window don't trip burst (exit=$T5_EXIT, not 3)"
else
    _fail "Test 5: burst incorrectly tripped by events outside window"
fi

echo ""

# ── Test 6: missing ambient log → count=0 (no burst) ─────────────────────────
echo "Test 6: missing ambient log → count=0, no burst"
T6_DIR="$TMPDIR_ROOT/t6"
mkdir -p "$T6_DIR"
# No ambient log file at all
T6_AMBIENT="$T6_DIR/no-such-ambient.jsonl"

T6_EXIT=0
"${BASE_ENV[@]}" \
    CHUMP_AMBIENT_LOG="$T6_AMBIENT" \
    CHUMP_ADMIN_MERGE_BURST_THRESHOLD=1 \
    bash "$SCRIPT" \
        --pr 105 \
        --noise-class test-burst-class \
    2>/dev/null || T6_EXIT=$?

# Should not exit 3 (no log = count 0, below threshold=1)
if [[ "$T6_EXIT" -ne 3 ]]; then
    _pass "Test 6: missing ambient log → count=0, no burst"
else
    _fail "Test 6: burst tripped on missing log (should be count=0)"
fi

echo ""

# ── Test 7: admin_merge_cycle_run emitted on success ─────────────────────────
echo "Test 7: admin_merge_cycle_run emitted after successful merge"
T7_DIR="$TMPDIR_ROOT/t7"
mkdir -p "$T7_DIR/ruleset-snapshots"
cp "$SNAPSHOT_DIR"/*.json "$T7_DIR/ruleset-snapshots/"
T7_AMBIENT="$T7_DIR/ambient.jsonl"
# 0 prior events — below threshold
> "$T7_AMBIENT"

T7_EXIT=0
"${BASE_ENV[@]}" \
    CHUMP_AMBIENT_LOG="$T7_AMBIENT" \
    CHUMP_ADMIN_MERGE_BURST_THRESHOLD=3 \
    bash "$SCRIPT" \
        --pr 106 \
        --noise-class test-burst-class \
    2>/dev/null || T7_EXIT=$?

if [[ "$T7_EXIT" -eq 0 ]]; then
    _pass "Test 7a: exits 0 (below threshold, merge succeeded)"
else
    _fail "Test 7a: unexpected exit $T7_EXIT"
fi

if grep -q '"kind":"admin_merge_cycle_run"' "$T7_AMBIENT" 2>/dev/null; then
    _pass "Test 7b: admin_merge_cycle_run emitted after successful merge"
else
    _fail "Test 7b: admin_merge_cycle_run NOT found in ambient log after merge"
fi

# Verify fields: pr, reason, operator_session_id
if grep '"kind":"admin_merge_cycle_run"' "$T7_AMBIENT" 2>/dev/null | python3 -c "
import sys, json
for line in sys.stdin:
    ev = json.loads(line)
    assert 'pr' in ev, 'missing pr'
    assert 'reason' in ev, 'missing reason'
    assert 'operator_session_id' in ev, 'missing operator_session_id'
print('ok')
" 2>/dev/null | grep -q ok; then
    _pass "Test 7c: admin_merge_cycle_run has required fields (pr, reason, operator_session_id)"
else
    _fail "Test 7c: admin_merge_cycle_run missing required fields"
fi

echo ""

# ── Test 8: --force-admin also overrides burst ────────────────────────────────
echo "Test 8: --force-admin also overrides burst, emits burst_overridden with override_method=--force-admin"
T8_DIR="$TMPDIR_ROOT/t8"
mkdir -p "$T8_DIR/ruleset-snapshots"
cp "$SNAPSHOT_DIR"/*.json "$T8_DIR/ruleset-snapshots/"
T8_AMBIENT="$T8_DIR/ambient.jsonl"
_make_ambient "$T8_AMBIENT" 3   # burst threshold hit

T8_EXIT=0
"${BASE_ENV[@]}" \
    CHUMP_AMBIENT_LOG="$T8_AMBIENT" \
    CHUMP_ADMIN_MERGE_BURST_THRESHOLD=3 \
    bash "$SCRIPT" \
        --pr 107 \
        --force-admin \
        --reason "emergency test override" \
    2>/dev/null || T8_EXIT=$?

if [[ "$T8_EXIT" -eq 0 ]]; then
    _pass "Test 8a: exits 0 with --force-admin override"
else
    _fail "Test 8a: expected exit 0, got $T8_EXIT"
fi

if grep -q '"kind":"admin_merge_burst_overridden"' "$T8_AMBIENT" 2>/dev/null; then
    _pass "Test 8b: admin_merge_burst_overridden emitted with --force-admin"
else
    _fail "Test 8b: admin_merge_burst_overridden NOT found"
fi

if grep '"kind":"admin_merge_burst_overridden"' "$T8_AMBIENT" 2>/dev/null | grep -q '"override_method":"--force-admin"'; then
    _pass "Test 8c: override_method=--force-admin"
else
    _fail "Test 8c: override_method not --force-admin"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
TOTAL=$(( PASS + FAIL ))
echo "Results: $PASS/$TOTAL PASS"
if [[ "$FAIL" -gt 0 ]]; then
    echo "FAIL: $FAIL test(s) failed" >&2
    exit 1
fi
echo "All tests passed."
