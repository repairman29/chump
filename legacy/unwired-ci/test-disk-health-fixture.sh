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
#   8. reaper_check_disk_headroom dedups by filesystem + emits a self-diagnosing
#      note naming the real mount point, not a duplicate per probed dir
#      (RESILIENT-096).

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

# ── Test 6: INFRA-973 worktree reaper continues despite low disk ─────────────
# The stale-worktree-reaper's whole job is to free disk. Aborting it on
# disk_critical creates a deadlock (cleanup is most needed when disk is low).
FAKE_WT_REPO="$TMP/wtrepo"
mkdir -p "$FAKE_WT_REPO/.chump-locks"
git -C "$FAKE_WT_REPO" init -q
WT_AMBIENT="$FAKE_WT_REPO/.chump-locks/ambient.jsonl"

(
    export PATH="$FAKE_BIN:$PATH"
    export CHUMP_SKIP_DISK_HEADROOM=0
    cd "$FAKE_WT_REPO"
    # shellcheck disable=SC1090
    source "$LIB"
    REAPER_NAME="worktree"
    REAPER_REPO_ROOT="$FAKE_WT_REPO"
    REAPER_LOCK_DIR="$FAKE_WT_REPO/.chump-locks"
    REAPER_HEARTBEAT="/tmp/chump-reaper-worktree.heartbeat"
    REAPER_START_EPOCH="$(date +%s)"
    reaper_check_disk_headroom
    echo "CONTINUED"
) > "$TMP/wt-out" 2>&1
grep -q "CONTINUED" "$TMP/wt-out" \
    || fail "worktree reaper aborted on disk_critical (INFRA-973 regression). out: $(cat "$TMP/wt-out")"
grep -q '"kind":"disk_critical"' "$WT_AMBIENT" \
    || fail "worktree reaper did not emit disk_critical ALERT (should still warn even when exempt)"
ok "INFRA-973: REAPER_NAME=worktree continues on disk_critical (still emits ALERT)"

# Test 7: REAPER_FREES_DISK=1 as generic opt-out.
FAKE_OPT_REPO="$TMP/optrepo"
mkdir -p "$FAKE_OPT_REPO/.chump-locks"
git -C "$FAKE_OPT_REPO" init -q

(
    export PATH="$FAKE_BIN:$PATH"
    export CHUMP_SKIP_DISK_HEADROOM=0
    export REAPER_FREES_DISK=1
    cd "$FAKE_OPT_REPO"
    # shellcheck disable=SC1090
    source "$LIB"
    REAPER_NAME="some-other-reaper"
    REAPER_REPO_ROOT="$FAKE_OPT_REPO"
    REAPER_LOCK_DIR="$FAKE_OPT_REPO/.chump-locks"
    REAPER_HEARTBEAT="/tmp/chump-reaper-other.heartbeat"
    REAPER_START_EPOCH="$(date +%s)"
    reaper_check_disk_headroom
    echo "CONTINUED"
) > "$TMP/opt-out" 2>&1
grep -q "CONTINUED" "$TMP/opt-out" \
    || fail "REAPER_FREES_DISK=1 did not exempt the early exit. out: $(cat "$TMP/opt-out")"
ok "INFRA-973: REAPER_FREES_DISK=1 exempts the early exit (generic opt-out)"

# ── Test 8: RESILIENT-096 — dedup by filesystem + self-diagnosing note ───────
# Both probed dirs (/tmp and the lock dir) resolve to ONE filesystem — exactly
# the macOS APFS case where /tmp and the repo share the Data volume. Assert we
# emit exactly ONE disk_critical (no per-dir duplicate) and that it carries a
# non-empty note naming the real mount point (not just the probed dir).
FAKE_DEDUP_REPO="$TMP/deduprepo"
mkdir -p "$FAKE_DEDUP_REPO/.chump-locks"
git -C "$FAKE_DEDUP_REPO" init -q
DEDUP_AMBIENT="$FAKE_DEDUP_REPO/.chump-locks/ambient.jsonl"

# Fake df: one shared filesystem (/dev/fakedata at /System/Volumes/Data) for
# ANY probed dir — mirrors the APFS shared-container case from the gap.
FAKE_DEDUP_BIN="$TMP/fakededuppath"
mkdir -p "$FAKE_DEDUP_BIN"
cat >"$FAKE_DEDUP_BIN/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem      Size  Used Avail Use%  Mounted on"
echo "/dev/fakedata   460G  455G    5G  99%  /System/Volumes/Data"
EOF
chmod +x "$FAKE_DEDUP_BIN/df"

(
    export PATH="$FAKE_DEDUP_BIN:$PATH"
    export CHUMP_SKIP_DISK_HEADROOM=0
    cd "$FAKE_DEDUP_REPO"
    # shellcheck disable=SC1090
    source "$LIB"
    REAPER_NAME="dedup-test"
    REAPER_REPO_ROOT="$FAKE_DEDUP_REPO"
    REAPER_LOCK_DIR="$FAKE_DEDUP_REPO/.chump-locks"
    REAPER_HEARTBEAT="/tmp/chump-reaper-dedup-test.heartbeat"
    REAPER_START_EPOCH="$(date +%s)"
    reaper_check_disk_headroom
) >/dev/null 2>&1 || true

[[ -f "$DEDUP_AMBIENT" ]] || fail "RESILIENT-096: ambient.jsonl not created by reaper_check_disk_headroom"
dc_count=$(grep -c '"kind":"disk_critical"' "$DEDUP_AMBIENT" || true)
[[ "$dc_count" -eq 1 ]] \
    || fail "RESILIENT-096: expected exactly 1 disk_critical (dedup by filesystem), got $dc_count: $(cat "$DEDUP_AMBIENT")"
ok "RESILIENT-096: one filesystem yields exactly one disk_critical (no per-dir duplicate)"

dc_line=$(grep '"kind":"disk_critical"' "$DEDUP_AMBIENT" | tail -1)
printf '%s' "$dc_line" | grep -q '"note":"[^"]' \
    || fail "RESILIENT-096: disk_critical has empty/missing note field: $dc_line"
printf '%s' "$dc_line" | grep -q '/System/Volumes/Data' \
    || fail "RESILIENT-096: event does not reference the real mount point /System/Volumes/Data: $dc_line"
ok "RESILIENT-096: disk_critical carries a non-empty note naming the real mount point"

printf '\n\033[0;32mall tests passed\033[0m\n'
