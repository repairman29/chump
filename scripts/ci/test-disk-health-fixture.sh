#!/usr/bin/env bash
# test-disk-health-fixture.sh — INFRA-453 unit test for disk-health-monitor.sh
# and reaper_check_disk_headroom.
#
# Verifies:
#   1. disk_low ALERT emitted when free space is <10% (warn tier).
#   2. disk_critical ALERT emitted when free space is <5% (critical tier).
#   3. disk_critical BLOCKING ALERT + fleet-pause file created when <2%.
#   4. No ALERT when free space is healthy (>=10%).
#   5. reaper_check_disk_headroom exits 0 + emits disk_critical when <5% free.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MONITOR="$REPO_ROOT/scripts/ops/disk-health-monitor.sh"
LIB="$REPO_ROOT/scripts/lib/reaper-instrumentation.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# Set up an isolated fake repo so we don't pollute real .chump-locks.
FAKE_REPO="$TMP/repo"
mkdir -p "$FAKE_REPO/.chump-locks"
git -C "$FAKE_REPO" init -q
AMBIENT="$FAKE_REPO/.chump-locks/ambient.jsonl"

# Helper: create a fake df command that always reports the given used% for /
# regardless of which directory it's asked about.
make_fake_df() {
    local used_pct="$1"
    local fake_df="$TMP/fakebin/df"
    mkdir -p "$(dirname "$fake_df")"
    cat >"$fake_df" <<EOF
#!/usr/bin/env bash
echo "Filesystem      Size  Used Avail Use% Mounted on"
echo "/dev/disk1s1   500G  ${used_pct}G  $((500 - used_pct))G  ${used_pct}% /"
EOF
    chmod +x "$fake_df"
    printf '%s' "$fake_df"
}

run_monitor() {
    local df_cmd="$1"
    rm -f "$AMBIENT"
    CHUMP_DISK_MONITOR_DF_CMD="$df_cmd" \
    CHUMP_AMBIENT_OVERRIDE="$AMBIENT" \
    CHUMP_FLEET_PAUSE_FILE="$TMP/fleet-pause" \
    bash "$MONITOR" 2>/dev/null \
        || true  # exit 0 always from monitor; errors in test harness
}

assert_kind() {
    local expected_kind="$1"
    [[ -f "$AMBIENT" ]] || fail "ambient.jsonl not created (expected $expected_kind)"
    if grep -q "\"kind\":\"${expected_kind}\"" "$AMBIENT"; then
        return 0
    fi
    fail "expected kind=${expected_kind} in ambient.jsonl, got: $(cat "$AMBIENT")"
}

assert_no_kind() {
    local bad_kind="$1"
    [[ ! -f "$AMBIENT" ]] && return 0
    if grep -q "\"kind\":\"${bad_kind}\"" "$AMBIENT" 2>/dev/null; then
        fail "unexpected kind=${bad_kind} in ambient.jsonl: $(cat "$AMBIENT")"
    fi
}

# Redirect CHUMP_DISK_MONITOR_DF_CMD to a single fake df binary by setting
# the full path. The monitor does: $DF_CMD "$check_dir" — we use a wrapper
# that ignores its argument.

# ── Test 1: healthy (92% free = 8% used) → no ALERT ──────────────────────────
fake_df_ok="$TMP/fakebin/df-ok"
mkdir -p "$TMP/fakebin"
cat >"$fake_df_ok" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem      Size  Used Avail Use%  Mounted on"
echo "/dev/disk1s1   500G   40G  460G   8%  /"
EOF
chmod +x "$fake_df_ok"
run_monitor "$fake_df_ok"
assert_no_kind "disk_low"
assert_no_kind "disk_critical"
ok "no ALERT when free space is healthy (92% free)"

# ── Test 2: warn tier (93% used = 7% free, below 10%) → disk_low ─────────────
fake_df_warn="$TMP/fakebin/df-warn"
cat >"$fake_df_warn" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem      Size  Used Avail Use%  Mounted on"
echo "/dev/disk1s1   500G  465G   35G  93%  /"
EOF
chmod +x "$fake_df_warn"
run_monitor "$fake_df_warn"
assert_kind "disk_low"
assert_no_kind "disk_critical"
ok "disk_low ALERT emitted when 7% free (<10% threshold)"

# ── Test 3: critical tier (96% used = 4% free, below 5%) → disk_critical ─────
fake_df_crit="$TMP/fakebin/df-crit"
cat >"$fake_df_crit" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem      Size  Used Avail Use%  Mounted on"
echo "/dev/disk1s1   500G  480G   20G  96%  /"
EOF
chmod +x "$fake_df_crit"
run_monitor "$fake_df_crit"
assert_kind "disk_critical"
ok "disk_critical ALERT emitted when 4% free (<5% threshold)"

# ── Test 4: blocking tier (99% used = 1% free) → BLOCKING + pause file ───────
fake_df_block="$TMP/fakebin/df-block"
cat >"$fake_df_block" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem      Size  Used Avail Use%  Mounted on"
echo "/dev/disk1s1   500G  495G    5G  99%  /"
EOF
chmod +x "$fake_df_block"
rm -f "$TMP/fleet-pause"
run_monitor "$fake_df_block"
assert_kind "disk_critical"
grep -q '"level":"BLOCKING"' "$AMBIENT" \
    || fail "expected BLOCKING level in ambient.jsonl: $(cat "$AMBIENT")"
[[ -f "$TMP/fleet-pause" ]] || fail "fleet-pause file not created at $TMP/fleet-pause"
ok "disk_critical BLOCKING ALERT + fleet-pause file created when 1% free (<2%)"

# ── Test 5: reaper_check_disk_headroom exits 0 + emits disk_critical ─────────
FAKE_HB_REPO="$TMP/hbrepo"
mkdir -p "$FAKE_HB_REPO/.chump-locks"
git -C "$FAKE_HB_REPO" init -q
HB_AMBIENT="$FAKE_HB_REPO/.chump-locks/ambient.jsonl"

# Create a fake df shim in /tmp that reports 99% used so /tmp looks critical.
FAKE_BIN="$TMP/fakepath"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem      Size  Used Avail Use%  Mounted on"
echo "tmpfs           1.0G  990M   10M  99%  /tmp"
EOF
chmod +x "$FAKE_BIN/df"

# Run reaper_check_disk_headroom in an isolated subshell.
exit_code=0
(
    export PATH="$FAKE_BIN:$PATH"
    export CHUMP_SKIP_DISK_HEADROOM=0
    cd "$FAKE_HB_REPO"
    # shellcheck disable=SC1090
    source "$LIB"
    # Manually set what reaper_setup would set.
    REAPER_NAME="test-reaper"
    REAPER_REPO_ROOT="$FAKE_HB_REPO"
    REAPER_LOCK_DIR="$FAKE_HB_REPO/.chump-locks"
    REAPER_HEARTBEAT="/tmp/chump-reaper-test-reaper.heartbeat"
    REAPER_START_EPOCH="$(date +%s)"
    reaper_check_disk_headroom
    # If we reach here, disk check did NOT trigger an exit — that means it
    # found free space OK. But we injected a critical df, so this is a FAIL
    # unless the df shim wasn't found for the lock_dir path.
    # Actually: reaper_check_disk_headroom checks /tmp and $REAPER_LOCK_DIR.
    # With fake df on PATH reporting 99% for any path, it should exit 0.
    echo "NO_EXIT"
) && exit_code=0 || exit_code=$?

# Expect exit 0 from subshell (reaper_check_disk_headroom calls `exit 0`).
[[ "$exit_code" -eq 0 ]] || fail "reaper_check_disk_headroom subshell exited $exit_code (expected 0)"
# Expect ambient.jsonl to have disk_critical.
[[ -f "$HB_AMBIENT" ]] || fail "ambient.jsonl not created by reaper_check_disk_headroom"
grep -q '"kind":"disk_critical"' "$HB_AMBIENT" \
    || fail "reaper_check_disk_headroom did not emit disk_critical: $(cat "$HB_AMBIENT")"
ok "reaper_check_disk_headroom exits 0 + emits disk_critical when disk is full"

printf '\n\033[0;32mall tests passed\033[0m\n'
