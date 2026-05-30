#!/usr/bin/env bash
# test-trunk-red-detector.sh — META-177 Lane C / META-179
#
# Asserts trunk-red-detector.sh behaves correctly across the key state
# transitions: failure detection, hysteresis, green resolution, state file
# format, and broadcast invocation.
#
# Pattern: 6-test bash counter (pass/fail) matching test-queue-driver-iter-no-repeat.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DETECTOR="$REPO_ROOT/scripts/coord/trunk-red-detector.sh"

pass=0; fail=0

# ── Test 1: script exists and is executable ───────────────────────────────────
if [[ -x "$DETECTOR" ]]; then
    echo "PASS 1: trunk-red-detector.sh exists and is executable"
    pass=$((pass+1))
else
    echo "FAIL 1: trunk-red-detector.sh missing or not executable at $DETECTOR"
    fail=$((fail+1))
fi

# ── Shared test fixtures ──────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

FIXTURE_FAILURE="$TMPDIR_TEST/run-failure.json"
FIXTURE_SUCCESS="$TMPDIR_TEST/run-success.json"
AMBIENT_FILE="$TMPDIR_TEST/ambient.jsonl"
STATE_FILE="$TMPDIR_TEST/trunk-red-state.json"

# Fixture: a failed run.
cat > "$FIXTURE_FAILURE" <<'EOF'
{
  "conclusion": "failure",
  "databaseId": 12345678,
  "createdAt": "2026-05-30T07:30:00Z",
  "headSha": "deadbeef1234567890abcdef01234567deadbeef"
}
EOF

# Fixture: a successful run.
cat > "$FIXTURE_SUCCESS" <<'EOF'
{
  "conclusion": "success",
  "databaseId": 12345679,
  "createdAt": "2026-05-30T08:00:00Z",
  "headSha": "abcdef1234567890deadbeef01234567abcdef12"
}
EOF

# Stub broadcast.sh — records calls without needing real broadcast infra.
BROADCAST_STUB="$TMPDIR_TEST/broadcast.sh"
BROADCAST_LOG="$TMPDIR_TEST/broadcast.log"
cat > "$BROADCAST_STUB" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BROADCAST_LOG"
EOF
chmod +x "$BROADCAST_STUB"

# ── Test 2: emits kind=trunk_red_detected on failure fixture ─────────────────
rm -f "$AMBIENT_FILE" "$STATE_FILE"
CHUMP_TRUNK_RED_GH_FIXTURE="$FIXTURE_FAILURE" \
CHUMP_TRUNK_RED_AMBIENT_FILE="$AMBIENT_FILE" \
CHUMP_TRUNK_RED_STATE_FILE="$STATE_FILE" \
CHUMP_TRUNK_RED_BROADCAST_SCRIPT="$BROADCAST_STUB" \
    bash "$DETECTOR" >/dev/null 2>&1 || true

if grep -q 'trunk_red_detected' "$AMBIENT_FILE" 2>/dev/null; then
    echo "PASS 2: kind=trunk_red_detected emitted to ambient on failure fixture"
    pass=$((pass+1))
else
    echo "FAIL 2: trunk_red_detected not found in ambient after failure fixture"
    fail=$((fail+1))
fi

# ── Test 3: hysteresis — second run within window is a no-op ─────────────────
# Run again immediately (state file still present, same SHA, interval not elapsed).
ambient_line_count_before="$(wc -l < "$AMBIENT_FILE" 2>/dev/null || echo 0)"
CHUMP_TRUNK_RED_GH_FIXTURE="$FIXTURE_FAILURE" \
CHUMP_TRUNK_RED_AMBIENT_FILE="$AMBIENT_FILE" \
CHUMP_TRUNK_RED_STATE_FILE="$STATE_FILE" \
CHUMP_TRUNK_RED_BROADCAST_SCRIPT="$BROADCAST_STUB" \
CHUMP_TRUNK_RED_EMIT_INTERVAL_S="3600" \
    bash "$DETECTOR" >/dev/null 2>&1 || true

ambient_line_count_after="$(wc -l < "$AMBIENT_FILE" 2>/dev/null || echo 0)"
if [[ "$ambient_line_count_after" -eq "$ambient_line_count_before" ]]; then
    echo "PASS 3: hysteresis — second run within 3600s window did not emit again"
    pass=$((pass+1))
else
    echo "FAIL 3: hysteresis failed — ambient grew from $ambient_line_count_before to $ambient_line_count_after lines"
    fail=$((fail+1))
fi

# ── Test 4: emits kind=trunk_red_resolved on success after red ───────────────
# State file from test 2 still present; now run with success fixture.
ambient_lines_before="$(wc -l < "$AMBIENT_FILE" 2>/dev/null || echo 0)"
CHUMP_TRUNK_RED_GH_FIXTURE="$FIXTURE_SUCCESS" \
CHUMP_TRUNK_RED_AMBIENT_FILE="$AMBIENT_FILE" \
CHUMP_TRUNK_RED_STATE_FILE="$STATE_FILE" \
CHUMP_TRUNK_RED_BROADCAST_SCRIPT="$BROADCAST_STUB" \
    bash "$DETECTOR" >/dev/null 2>&1 || true

if grep -q 'trunk_red_resolved' "$AMBIENT_FILE" 2>/dev/null; then
    echo "PASS 4: kind=trunk_red_resolved emitted when transitioning failure -> success"
    pass=$((pass+1))
else
    echo "FAIL 4: trunk_red_resolved not found in ambient after success fixture"
    fail=$((fail+1))
fi

# State file should be cleared after green.
if [[ ! -f "$STATE_FILE" ]]; then
    echo "      (state file correctly cleared on green)"
fi

# ── Test 5: state file location and required fields ──────────────────────────
# Re-run failure fixture to produce a fresh state file.
rm -f "$AMBIENT_FILE" "$STATE_FILE"
CHUMP_TRUNK_RED_GH_FIXTURE="$FIXTURE_FAILURE" \
CHUMP_TRUNK_RED_AMBIENT_FILE="$AMBIENT_FILE" \
CHUMP_TRUNK_RED_STATE_FILE="$STATE_FILE" \
CHUMP_TRUNK_RED_BROADCAST_SCRIPT="$BROADCAST_STUB" \
CHUMP_TRUNK_RED_EMIT_INTERVAL_S="0" \
    bash "$DETECTOR" >/dev/null 2>&1 || true

state_ok=1
for field in last_emit_ts last_failed_sha red_since_ts failed_run_id; do
    if ! grep -q "\"$field\"" "$STATE_FILE" 2>/dev/null; then
        echo "FAIL 5: state file missing field: $field"
        state_ok=0
        break
    fi
done
if [[ "$state_ok" -eq 1 ]]; then
    echo "PASS 5: state file at correct location with required fields (last_emit_ts, last_failed_sha, red_since_ts, failed_run_id)"
    pass=$((pass+1))
else
    fail=$((fail+1))
fi

# ── Test 6: broadcast.sh invocation present in source ────────────────────────
if grep -q 'BROADCAST_SCRIPT' "$DETECTOR" 2>/dev/null \
   && grep -q 'broadcast.sh' "$DETECTOR" 2>/dev/null; then
    echo "PASS 6: broadcast.sh invocation present in trunk-red-detector.sh source"
    pass=$((pass+1))
else
    echo "FAIL 6: broadcast.sh reference not found in trunk-red-detector.sh source"
    fail=$((fail+1))
fi

echo
if [[ "$fail" -eq 0 ]]; then
    echo "test-trunk-red-detector: ALL $pass passed"
    exit 0
else
    echo "test-trunk-red-detector: $pass passed, $fail failed"
    exit 1
fi
