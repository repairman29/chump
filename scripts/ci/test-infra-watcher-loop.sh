#!/usr/bin/env bash
# scripts/ci/test-infra-watcher-loop.sh — smoke test for infra-watcher-loop.sh
# META-102: curator-opus-infra-watcher productization
#
# Cases:
#   1. Synthetic plist missing StartInterval → assert daemon_plist_missing_interval finding
#   2. Synthetic runner queue (queued >5min + idle online) → assert runner_ghost_online finding
#   3. Synthetic df at 90% → assert disk_pressure finding
#   4. Synthetic claude proc count 200 → assert process_bloat finding
#   5. All-green case → exit 0, no findings emitted

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOOP="${REPO_ROOT}/scripts/coord/infra-watcher-loop.sh"

PASS=0
FAIL=0

# ── Test harness ──────────────────────────────────────────────────────────────

_assert_finding() {
    local log="$1"
    local category="$2"
    local label="$3"
    if grep -q "\"category\":\"${category}\"" "$log" 2>/dev/null; then
        printf 'PASS: %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'FAIL: %s — expected category=%s in ambient log\n' "$label" "$category" >&2
        printf '  log contents:\n' >&2
        cat "$log" >&2
        FAIL=$((FAIL + 1))
    fi
}

_assert_no_findings() {
    local log="$1"
    local label="$2"
    if grep -q '"kind":"infra_watcher_finding"' "$log" 2>/dev/null; then
        printf 'FAIL: %s — unexpected findings in ambient log\n' "$label" >&2
        cat "$log" >&2
        FAIL=$((FAIL + 1))
    else
        printf 'PASS: %s\n' "$label"
        PASS=$((PASS + 1))
    fi
}

_setup_env() {
    # Each test case gets an isolated tmpdir + ambient log
    local testdir
    testdir="$(mktemp -d)"
    export AMBIENT_LOG="${testdir}/ambient.jsonl"
    touch "$AMBIENT_LOG"
    # Override the repo root ambient log path
    # infra-watcher-loop.sh writes to ${REPO_ROOT}/.chump-locks/ambient.jsonl
    # We inject via a wrapper that sets REPO_ROOT to testdir
    export _TEST_REPO_ROOT="$testdir"
    mkdir -p "${testdir}/.chump-locks"
    # Re-point AMBIENT_LOG so the loop writes to our test copy
    export CHUMP_INFRA_WATCHER_AMBIENT_LOG="${testdir}/.chump-locks/ambient.jsonl"
    printf '%s\n' "$testdir"
}

# Wrapper: runs infra-watcher-loop.sh with REPO_ROOT redirected so ambient writes
# land in the test tmpdir's .chump-locks/ambient.jsonl
_run_loop() {
    local testdir="$1"
    shift
    env REPO_ROOT="$testdir" bash "$LOOP" "$@"
}

# ── Case 1: daemon plist missing StartInterval ─────────────────────────────────
test_daemon_plist_missing_interval() {
    local testdir
    testdir="$(_setup_env)"

    local plist_dir="${testdir}/LaunchAgents"
    mkdir -p "$plist_dir"
    # Write a synthetic plist WITHOUT StartInterval or StartCalendarInterval
    cat > "${plist_dir}/com.chump.prune-worktrees.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.chump.prune-worktrees</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/jeffadkins/Projects/Chump/scripts/ops/prune-worktrees.sh</string>
    </array>
</dict>
</plist>
EOF

    export CHUMP_INFRA_WATCHER_PLIST_DIR="$plist_dir"
    _run_loop "$testdir" audit-daemons 2>/dev/null || true

    _assert_finding \
        "${testdir}/.chump-locks/ambient.jsonl" \
        "daemon_plist_missing_interval" \
        "Case 1: synthetic plist missing StartInterval → daemon_plist_missing_interval"

    rm -rf "$testdir"
    unset CHUMP_INFRA_WATCHER_PLIST_DIR
}

# ── Case 2: runner ghost-online ────────────────────────────────────────────────
test_runner_ghost_online() {
    local testdir
    testdir="$(_setup_env)"

    # Stub gh to return: one idle online runner + one job queued 10min ago
    local stub_dir="${testdir}/stubs"
    mkdir -p "$stub_dir"

    local ten_min_ago
    ten_min_ago="$(python3 -c "
from datetime import datetime, timezone, timedelta
t = datetime.now(timezone.utc) - timedelta(minutes=10)
print(t.strftime('%Y-%m-%dT%H:%M:%SZ'))
" 2>/dev/null || date -u -v-10M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u --date='10 minutes ago' +"%Y-%m-%dT%H:%M:%SZ")"

    cat > "${stub_dir}/gh" <<EOF
#!/usr/bin/env bash
# Stub gh for runner ghost-online test
if [[ "\$*" == *"actions/runners"* ]]; then
    printf '{"runners":[{"id":1,"name":"mac-runner-1","status":"online","busy":false}]}\n'
elif [[ "\$*" == *"run list"* ]]; then
    printf '[{"databaseId":9001,"createdAt":"${ten_min_ago}","status":"queued"}]\n'
else
    printf '[]\n'
fi
EOF
    chmod +x "${stub_dir}/gh"

    # Also stub git remote get-url for repo name derivation
    cat > "${stub_dir}/git" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"remote get-url"* ]]; then
    printf 'https://github.com/repairman29/Chump.git\n'
else
    command git "$@"
fi
EOF
    chmod +x "${stub_dir}/git"

    export CHUMP_GH_BIN="${stub_dir}/gh"
    export PATH="${stub_dir}:${PATH}"
    export CHUMP_INFRA_WATCHER_PLIST_DIR="${testdir}/empty-plists"
    mkdir -p "${testdir}/empty-plists"

    _run_loop "$testdir" check-runners 2>/dev/null || true

    _assert_finding \
        "${testdir}/.chump-locks/ambient.jsonl" \
        "runner_ghost_online" \
        "Case 2: queued job >5min + idle runner → runner_ghost_online"

    rm -rf "$testdir"
    unset CHUMP_GH_BIN CHUMP_INFRA_WATCHER_PLIST_DIR
}

# ── Case 3: disk pressure at 90% ──────────────────────────────────────────────
test_disk_pressure() {
    local testdir
    testdir="$(_setup_env)"

    # Stub df to return 90% used
    local stub_dir="${testdir}/stubs"
    mkdir -p "$stub_dir"
    cat > "${stub_dir}/df" <<'EOF'
#!/usr/bin/env bash
# Synthetic df output at 90%
printf 'Filesystem      Size   Used  Avail Capacity  Mounted on\n'
printf '/dev/disk1s1   500G   450G   50G    90%%  /tmp\n'
EOF
    chmod +x "${stub_dir}/df"

    export CHUMP_DF_BIN="${stub_dir}/df"

    _run_loop "$testdir" check-disk 2>/dev/null || true

    _assert_finding \
        "${testdir}/.chump-locks/ambient.jsonl" \
        "disk_pressure" \
        "Case 3: synthetic df 90% → disk_pressure"

    rm -rf "$testdir"
    unset CHUMP_DF_BIN
}

# ── Case 4: claude proc count 200 ─────────────────────────────────────────────
test_process_bloat() {
    local testdir
    testdir="$(_setup_env)"

    # Stub pgrep to return 200 lines (one PID per line)
    local stub_dir="${testdir}/stubs"
    mkdir -p "$stub_dir"
    cat > "${stub_dir}/pgrep" <<'EOF'
#!/usr/bin/env bash
# Return 200 synthetic PIDs regardless of pattern
seq 10000 10199
EOF
    chmod +x "${stub_dir}/pgrep"

    export CHUMP_PGREP_BIN="${stub_dir}/pgrep"

    _run_loop "$testdir" check-procs 2>/dev/null || true

    _assert_finding \
        "${testdir}/.chump-locks/ambient.jsonl" \
        "process_bloat" \
        "Case 4: 200 claude procs → process_bloat"

    rm -rf "$testdir"
    unset CHUMP_PGREP_BIN
}

# ── Case 5: all-green — no findings ───────────────────────────────────────────
test_all_green() {
    local testdir
    testdir="$(_setup_env)"

    # Plist dir with a well-formed plist (has StartInterval)
    local plist_dir="${testdir}/LaunchAgents"
    mkdir -p "$plist_dir"
    cat > "${plist_dir}/com.chump.healthy-daemon.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.chump.healthy-daemon</string>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/jeffadkins/Projects/Chump/scripts/ops/healthy-daemon.sh</string>
    </array>
</dict>
</plist>
EOF
    export CHUMP_INFRA_WATCHER_PLIST_DIR="$plist_dir"

    # Stub gh to return: no runners (so ghost-online can't fire)
    local stub_dir="${testdir}/stubs"
    mkdir -p "$stub_dir"
    cat > "${stub_dir}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"actions/runners"* ]]; then
    printf '{"runners":[]}\n'
else
    printf '[]\n'
fi
EOF
    chmod +x "${stub_dir}/gh"
    export CHUMP_GH_BIN="${stub_dir}/gh"

    # Stub df to return healthy 40%
    cat > "${stub_dir}/df" <<'EOF'
#!/usr/bin/env bash
printf 'Filesystem      Size   Used  Avail Capacity  Mounted on\n'
printf '/dev/disk1s1   500G   200G   300G    40%%  /tmp\n'
EOF
    chmod +x "${stub_dir}/df"
    export CHUMP_DF_BIN="${stub_dir}/df"

    # Stub pgrep to return 5 PIDs (well below threshold)
    cat > "${stub_dir}/pgrep" <<'EOF'
#!/usr/bin/env bash
seq 1001 1005
EOF
    chmod +x "${stub_dir}/pgrep"
    export CHUMP_PGREP_BIN="${stub_dir}/pgrep"

    _run_loop "$testdir" tick 2>/dev/null || true

    _assert_no_findings \
        "${testdir}/.chump-locks/ambient.jsonl" \
        "Case 5: all-green → no infra_watcher_finding events"

    rm -rf "$testdir"
    unset CHUMP_INFRA_WATCHER_PLIST_DIR CHUMP_GH_BIN CHUMP_DF_BIN CHUMP_PGREP_BIN
}

# ── Run all cases ──────────────────────────────────────────────────────────────
printf '=== test-infra-watcher-loop.sh ===\n'
printf 'Loop script: %s\n\n' "$LOOP"

if [[ ! -f "$LOOP" ]]; then
    printf 'FATAL: loop script not found: %s\n' "$LOOP" >&2
    exit 1
fi

test_daemon_plist_missing_interval
test_runner_ghost_online
test_disk_pressure
test_process_bloat
test_all_green

# ── Case: Phase 0 inbox-drain smoke test (META-161) ───────────────────────────
test_phase0_inbox_drain() {
    local T
    T="$(mktemp -d)"
    trap 'rm -rf "$T"' RETURN

    # Copy loop + shared lib
    mkdir -p "$T/scripts/coord/lib"
    cp "$LOOP" "$T/scripts/coord/infra-watcher-loop.sh"
    local helpers
    helpers="$(cd "$(dirname "$LOOP")" && pwd)/lib/inbox-helpers.sh"
    [[ -f "$helpers" ]] && cp "$helpers" "$T/scripts/coord/lib/inbox-helpers.sh"

    local session_id="test-iw-phase0-$$"
    mkdir -p "$T/.chump-locks/inbox"

    # 1 inbox message
    printf '{"ts":"2026-05-30T00:00:00Z","kind":"test_msg","session":"%s"}\n' "$session_id" \
        > "$T/.chump-locks/inbox/${session_id}.jsonl"

    # 1 ambient FEEDBACK event with unresolved corr_id
    printf '{"ts":"2026-05-30T00:00:01Z","kind":"FEEDBACK","corr_id":"corr-iw-123","session":"other"}\n' \
        > "$T/.chump-locks/ambient.jsonl"

    local out rc=0
    out="$(
        REPO_ROOT="$T" \
        CHUMP_IW_AMBIENT_LOG="$T/.chump-locks/ambient.jsonl" \
        CHUMP_IW_LOCK_DIR="$T/.chump-locks" \
        CHUMP_SESSION_ID="$session_id" \
        CHUMP_FLEET_RECV_SIDE_V0=1 \
        CHUMP_INFRA_WATCHER_PLIST_DIR="$T/no-plists" \
            bash "$T/scripts/coord/infra-watcher-loop.sh" tick 2>&1
    )" || rc=$?

    if printf '%s' "$out" | grep -q "Pending FEEDBACK"; then
        PASS=$((PASS+1)); printf 'PASS Phase 0 infra-watcher: Pending FEEDBACK header present\n'
    else
        FAIL=$((FAIL+1)); printf 'FAIL Phase 0 infra-watcher: Pending FEEDBACK header missing; output=%s\n' "$out"
    fi
    if printf '%s' "$out" | grep -q "Phase 0"; then
        PASS=$((PASS+1)); printf 'PASS Phase 0 infra-watcher: Phase 0 header present\n'
    else
        FAIL=$((FAIL+1)); printf 'FAIL Phase 0 infra-watcher: Phase 0 header missing\n'
    fi
}
test_phase0_inbox_drain

printf '\n=== Results: %d passed, %d failed ===\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
