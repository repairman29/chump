#!/usr/bin/env bash
# test-observability-loop.sh — META-103 smoke test
#
# Exercises scripts/coord/observability-loop.sh with:
#   - Stubbed `gh`, `launchctl` on PATH
#   - Synthetic ambient.jsonl and plist files
#
# Cases:
#   1. zero-emit kind in registry → finding category=zero_emit_kind
#   2. >100/day kind in ambient → finding category=high_volume_kind
#   3. plist with cadence drift (ratio >4×) → finding category=reaper_cadence_drift
#   4. all-coherent case → exit 0, no findings
#
# Network-free: no gh/launchctl calls needed for core subcommands.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/observability-loop.sh"

[[ -x "$SCRIPT" ]] || chmod +x "$SCRIPT"
[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/LaunchAgents"
export PATH="$TMP/bin:$PATH"

AMBIENT="$TMP/ambient.jsonl"
REGISTRY="$TMP/event-registry.txt"

# Stub gh (not needed by core subcommands — here as safety net)
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "[]"
STUB
chmod +x "$TMP/bin/gh"

# Stub launchctl (not needed — plist parsing is done via python3)
cat > "$TMP/bin/launchctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP/bin/launchctl"

# Helper: write a minimal binary plist (StartInterval) using python3 plistlib
write_plist() {
    local path="$1" interval="$2"
    python3 - "$path" "$interval" <<'PY'
import plistlib, sys
path, interval = sys.argv[1], int(sys.argv[2])
data = {
    "Label": f"com.chump.test-reaper-{interval}",
    "ProgramArguments": ["/bin/bash", "-c", "echo reap"],
    "StartInterval": interval,
}
with open(path, "wb") as f:
    plistlib.dump(data, f)
PY
}

# Helper: assert a finding category appears in ambient
assert_finding() {
    local test_name="$1" expected_category="$2"
    if grep -q "\"category\":\"${expected_category}\"" "$AMBIENT" 2>/dev/null; then
        echo "  PASS: $test_name → found category=${expected_category}"
    else
        echo "  FAIL: $test_name — expected category=${expected_category} in ambient"
        echo "  Ambient contents:"
        cat "$AMBIENT" 2>/dev/null || echo "  (empty)"
        exit 1
    fi
}

# Helper: assert NO findings in ambient
assert_no_findings() {
    local test_name="$1"
    if grep -q '"kind":"observability_finding"' "$AMBIENT" 2>/dev/null; then
        echo "  FAIL: $test_name — unexpected findings in ambient:"
        grep '"kind":"observability_finding"' "$AMBIENT"
        exit 1
    else
        echo "  PASS: $test_name → no findings (as expected)"
    fi
}

# ── Test 1: zero-emit kind → category=zero_emit_kind ─────────────────────────
echo "Test 1: zero-emit kind in registry → observability_finding category=zero_emit_kind"

> "$AMBIENT"
# Registry has one kind that never appears in ambient
cat > "$REGISTRY" <<'REG'
# test registry
kind_that_never_fires
kind_that_fires
REG

# Ambient has events only for kind_that_fires (older than 7d window doesn't matter here —
# we populate within last 7d by using current timestamps)
NOW_TS="$(python3 -c "import datetime; print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))")"
printf '{"ts":"%s","kind":"kind_that_fires"}\n' "$NOW_TS" >> "$AMBIENT"

> "$AMBIENT"
printf '{"ts":"%s","kind":"kind_that_fires"}\n' "$NOW_TS" >> "$AMBIENT"

CHUMP_OBS_CHUMP_OBS_EVENT_REGISTRY="$REGISTRY" \
CHUMP_AMBIENT_OVERRIDE="$AMBIENT" \
CHUMP_LAUNCHAGENTS_OVERRIDE="$TMP/LaunchAgents" \
CHUMP_OBS_DRY_RUN=0 \
CHUMP_OBS_ZERO_EMIT_DAYS=7 \
    "$SCRIPT" audit-event-registry > /dev/null

assert_finding "Test 1" "zero_emit_kind"

# ── Test 2: >100/day kind → category=high_volume_kind ────────────────────────
echo "Test 2: >100/day kind in registry → observability_finding category=high_volume_kind"

> "$AMBIENT"
cat > "$REGISTRY" <<'REG'
# test registry
noisy_kind
REG

# Emit 150 events for noisy_kind within last 7d
for i in $(seq 1 150); do
    printf '{"ts":"%s","kind":"noisy_kind"}\n' "$NOW_TS" >> "$AMBIENT"
done

CHUMP_OBS_EVENT_REGISTRY="$REGISTRY" \
CHUMP_AMBIENT_OVERRIDE="$AMBIENT" \
CHUMP_LAUNCHAGENTS_OVERRIDE="$TMP/LaunchAgents" \
CHUMP_OBS_DRY_RUN=0 \
CHUMP_OBS_ZERO_EMIT_DAYS=1 \
CHUMP_OBS_HIGH_VOLUME_PER_DAY=100 \
    "$SCRIPT" audit-event-registry > /dev/null

assert_finding "Test 2" "high_volume_kind"

# ── Test 3: reaper cadence drift → category=reaper_cadence_drift ─────────────
echo "Test 3: plist cadence drift (300s vs 1800s, ratio=6×) → observability_finding category=reaper_cadence_drift"

> "$AMBIENT"
mkdir -p "$TMP/LaunchAgents"
write_plist "$TMP/LaunchAgents/com.chump.claude-reaper.plist" 300
write_plist "$TMP/LaunchAgents/com.chump.subagent-reaper.plist" 1800

CHUMP_OBS_EVENT_REGISTRY="$REGISTRY" \
CHUMP_AMBIENT_OVERRIDE="$AMBIENT" \
CHUMP_LAUNCHAGENTS_OVERRIDE="$TMP/LaunchAgents" \
CHUMP_OBS_DRY_RUN=0 \
    "$SCRIPT" reaper-cadence-audit > /dev/null

assert_finding "Test 3" "reaper_cadence_drift"

# ── Test 4: all-coherent case → no findings ───────────────────────────────────
echo "Test 4: all-coherent (plists within 4×, registry kinds all emit at normal rate) → no findings"

> "$AMBIENT"

# Registry with one kind that fires at normal rate (50/day over 1-day window)
cat > "$REGISTRY" <<'REG'
# test registry
normal_kind
REG
for i in $(seq 1 50); do
    printf '{"ts":"%s","kind":"normal_kind"}\n' "$NOW_TS" >> "$AMBIENT"
done

# Plists within 4× (300s vs 900s = 3× ratio — coherent)
rm -f "$TMP/LaunchAgents"/*.plist
write_plist "$TMP/LaunchAgents/com.chump.claude-reaper.plist" 300
write_plist "$TMP/LaunchAgents/com.chump.subagent-reaper.plist" 900

# Run full tick
> "$AMBIENT"  # clear before tick so we only see findings from this run
for i in $(seq 1 50); do
    printf '{"ts":"%s","kind":"normal_kind"}\n' "$NOW_TS" >> "$AMBIENT"
done

CHUMP_OBS_EVENT_REGISTRY="$REGISTRY" \
CHUMP_AMBIENT_OVERRIDE="$AMBIENT" \
CHUMP_LAUNCHAGENTS_OVERRIDE="$TMP/LaunchAgents" \
CHUMP_OBS_DRY_RUN=0 \
CHUMP_OBS_ZERO_EMIT_DAYS=1 \
CHUMP_OBS_HIGH_VOLUME_PER_DAY=100 \
    "$SCRIPT" audit-event-registry > /dev/null

CHUMP_OBS_EVENT_REGISTRY="$REGISTRY" \
CHUMP_AMBIENT_OVERRIDE="$AMBIENT" \
CHUMP_LAUNCHAGENTS_OVERRIDE="$TMP/LaunchAgents" \
CHUMP_OBS_DRY_RUN=0 \
    "$SCRIPT" reaper-cadence-audit > /dev/null

# Only ambient writes for these invocations are the normal_kind events we put there.
# observability_finding should NOT appear.
assert_no_findings "Test 4"

# ── Test 5: detector-noise-rank → high_volume_kind for >100/24h ──────────────
echo "Test 5: detector-noise-rank → observability_finding category=high_volume_kind for >100/24h kind"

> "$AMBIENT"
for i in $(seq 1 110); do
    printf '{"ts":"%s","kind":"loud_detector"}\n' "$NOW_TS" >> "$AMBIENT"
done

CHUMP_AMBIENT_OVERRIDE="$AMBIENT" \
CHUMP_LAUNCHAGENTS_OVERRIDE="$TMP/LaunchAgents" \
CHUMP_OBS_DRY_RUN=0 \
CHUMP_OBS_HIGH_VOLUME_PER_DAY=100 \
    "$SCRIPT" detector-noise-rank > /dev/null

assert_finding "Test 5" "high_volume_kind"

# ── Test 6 (META-161): Phase 0 inbox-drain smoke test ─────────────────────────
echo ""
echo "Test 6 (META-161): Phase 0 inbox-drain — stub inbox + FEEDBACK, assert header"

_T6="$(mktemp -d)"
trap 'rm -rf "$_T6"' EXIT

# Copy loop + shared lib
mkdir -p "$_T6/scripts/coord/lib"
cp "$SCRIPT" "$_T6/scripts/coord/observability-loop.sh"
_helpers="$(cd "$(dirname "$SCRIPT")" && pwd)/lib/inbox-helpers.sh"
[[ -f "$_helpers" ]] && cp "$_helpers" "$_T6/scripts/coord/lib/inbox-helpers.sh"

_SESSION6="test-obs-phase0-$$"
mkdir -p "$_T6/.chump-locks/inbox"
> "$_T6/.chump-locks/ambient.jsonl"

# 1 inbox message
printf '{"ts":"2026-05-30T00:00:00Z","kind":"test_msg","session":"%s"}\n' "$_SESSION6" \
    > "$_T6/.chump-locks/inbox/${_SESSION6}.jsonl"

# 1 ambient FEEDBACK event with unresolved corr_id
printf '{"ts":"2026-05-30T00:00:01Z","kind":"FEEDBACK","corr_id":"corr-obs-789","session":"other"}\n' \
    >> "$_T6/.chump-locks/ambient.jsonl"

_out6=""
_out6="$(
    CHUMP_AMBIENT_OVERRIDE="$_T6/.chump-locks/ambient.jsonl" \
    CHUMP_OBS_LOCK_DIR="$_T6/.chump-locks" \
    CHUMP_SESSION_ID="$_SESSION6" \
    CHUMP_FLEET_RECV_SIDE_V0=1 \
    CHUMP_OBS_DRY_RUN=1 \
    CHUMP_LAUNCHAGENTS_OVERRIDE="$_T6/no-agents" \
        bash "$_T6/scripts/coord/observability-loop.sh" tick 2>&1
)" || true

_t6_pass=0
if printf '%s' "$_out6" | grep -q "Pending FEEDBACK"; then
    echo "PASS Test 6: 'Pending FEEDBACK' header present"
    _t6_pass=$((_t6_pass+1))
else
    echo "FAIL Test 6: 'Pending FEEDBACK' header missing; output: $_out6"
    exit 1
fi
if printf '%s' "$_out6" | grep -q "Phase 0"; then
    echo "PASS Test 6: Phase 0 header present"
else
    echo "FAIL Test 6: Phase 0 header missing"
    exit 1
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "All 6 observability-loop smoke tests passed."
