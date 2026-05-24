#!/usr/bin/env bash
# test-audit-allowlist-staleness.sh — INFRA-1868
#
# Smoke-tests for scripts/ops/audit-allowlist-staleness.sh:
#
#   1. An entry with a code reference is NOT flagged as stale
#   2. A synthetic entry absent from code for 0 days is NOT flagged (threshold=31)
#   3. A synthetic entry absent from code for 31+ days IS flagged as stale
#   4. kind=allowlist_stale_entry is emitted to ambient.jsonl with required fields
#      (entry, file, days_since_seen)
#   5. Script exits 1 when stale entries exist, 0 when none
#   6. --dry-run suppresses state write and ambient emit but still exits 1 on stale
#   7. Script is WARN-only — never deletes or modifies the allowlist files

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUDIT_SCRIPT="$REPO_ROOT/scripts/ops/audit-allowlist-staleness.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

[[ -f "$AUDIT_SCRIPT" ]]  || fail "audit-allowlist-staleness.sh not found at $AUDIT_SCRIPT"
[[ -x "$AUDIT_SCRIPT" ]]  || fail "audit-allowlist-staleness.sh is not executable"

TMP="$(mktemp -d -t test-allowlist-staleness.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── Synthetic test environment ────────────────────────────────────────────────
# Fake lock dir (ambient + state file live here).
FAKE_LOCK="$TMP/locks"
mkdir -p "$FAKE_LOCK"
FAKE_AMBIENT="$FAKE_LOCK/ambient.jsonl"
FAKE_STATE="$FAKE_LOCK/allowlist-staleness.json"

# Fake code tree — ONLY contains what the test controls.
# CHUMP_ALLOWLIST_CODE_ROOT is set to this tree so the grep never touches
# real repo files. This prevents test-fixture strings like CHUMP_STALE_ENTRY
# from matching in the real scripts/ directory.
FAKE_CODE="$TMP/code"
mkdir -p "$FAKE_CODE/src"
# The "present" entry IS referenced here.
cat > "$FAKE_CODE/src/present_feature.rs" <<'RUST'
// This file references CHUMP_PRESENT_ENTRY for testing purposes.
fn foo() { let _ = "CHUMP_PRESENT_ENTRY"; }
RUST
# CHUMP_STALE_ENTRY intentionally NOT present in fake code tree.

# Fake allowlist files.
FAKE_RESERVED="$TMP/event-registry-reserved.txt"
cat > "$FAKE_RESERVED" <<'EOF'
# comment — ignored
CHUMP_PRESENT_ENTRY  # reason: test fixture — entry IS in fake code tree
CHUMP_STALE_ENTRY    # reason: test fixture — entry NOT in fake code tree
EOF

FAKE_ENVVARS="$TMP/env-vars-internal.txt"
cat > "$FAKE_ENVVARS" <<'EOF'
# env vars for test — empty
EOF

# ── Core env helper ──────────────────────────────────────────────────────────
# All audit runs use FAKE_CODE as CODE_ROOT so grep stays inside the fake tree.
_audit_env() {
    env \
        CHUMP_LOCK_DIR="$FAKE_LOCK" \
        CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" \
        CHUMP_ALLOWLIST_STATE="$FAKE_STATE" \
        CHUMP_ALLOWLIST_RESERVED="$FAKE_RESERVED" \
        CHUMP_ALLOWLIST_ENVVARS="$FAKE_ENVVARS" \
        CHUMP_ALLOWLIST_CODE_ROOT="$FAKE_CODE" \
        CHUMP_AUDIT_ALLOWLIST_STALENESS=1 \
        "$@"
}

run_audit() {
    _audit_env bash "$AUDIT_SCRIPT" "$@" 2>&1 || true
}

run_audit_rc() {
    local rc=0
    _audit_env bash "$AUDIT_SCRIPT" "$@" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

# ── AC #7: WARN-only — audit must not delete or modify allowlist files ────────
RESERVED_BEFORE="$(md5 -q "$FAKE_RESERVED" 2>/dev/null || md5sum "$FAKE_RESERVED" | awk '{print $1}')"
ENVVARS_BEFORE="$(md5 -q "$FAKE_ENVVARS" 2>/dev/null || md5sum "$FAKE_ENVVARS" | awk '{print $1}')"

run_audit --stale-days 0 >/dev/null 2>&1 || true

RESERVED_AFTER="$(md5 -q "$FAKE_RESERVED" 2>/dev/null || md5sum "$FAKE_RESERVED" | awk '{print $1}')"
ENVVARS_AFTER="$(md5 -q "$FAKE_ENVVARS" 2>/dev/null || md5sum "$FAKE_ENVVARS" | awk '{print $1}')"
[[ "$RESERVED_BEFORE" == "$RESERVED_AFTER" ]] || fail "AC #7: audit modified event-registry-reserved.txt (must be WARN-only)"
[[ "$ENVVARS_BEFORE" == "$ENVVARS_AFTER" ]]   || fail "AC #7: audit modified env-vars-internal.txt (must be WARN-only)"
pass "AC #7: allowlist files unmodified — script is WARN-only"

# Reset state for clean test slate.
rm -f "$FAKE_STATE" "$FAKE_AMBIENT"

# ── Test 1: present entry NOT flagged ─────────────────────────────────────────
out1="$(run_audit --stale-days 0)"
# CHUMP_PRESENT_ENTRY is in fake code — should never appear in stale output.
if echo "$out1" | grep -q "stale" && echo "$out1" | grep "CHUMP_PRESENT_ENTRY" | grep -qi "stale"; then
    fail "Test 1: CHUMP_PRESENT_ENTRY (in code) should NOT be flagged as stale; got: $out1"
fi
pass "Test 1: entry with code reference NOT flagged as stale"

# ── Test 2: absent entry for 0 days NOT stale at threshold=31 ────────────────
rm -f "$FAKE_STATE" "$FAKE_AMBIENT"
rc2="$(run_audit_rc --stale-days 31)"
[[ "$rc2" -eq 0 ]] || fail "Test 2: first-day absence at threshold=31 should not be stale (exit 0), got exit $rc2"
pass "Test 2: first-day absence below threshold correctly NOT flagged"

# ── Test 3: synthetic stale entry (absent_since back-dated 31 days) ───────────
rm -f "$FAKE_AMBIENT"
ABSENT_SINCE=$(python3 -c "
import datetime
dt = datetime.datetime.utcnow() - datetime.timedelta(days=31)
print(dt.strftime('%Y-%m-%dT%H:%M:%SZ'))
" 2>/dev/null)
NOW_TS=$(python3 -c "import datetime; print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null)

# Inject state marking CHUMP_STALE_ENTRY as absent for 31 days.
cat > "$FAKE_STATE" <<STATE
{
  "event-registry-reserved.txt:CHUMP_STALE_ENTRY": {
    "last_seen": null,
    "absent_since": "$ABSENT_SINCE"
  },
  "event-registry-reserved.txt:CHUMP_PRESENT_ENTRY": {
    "last_seen": "$NOW_TS",
    "absent_since": null
  }
}
STATE

rc3=0
out3="$(_audit_env bash "$AUDIT_SCRIPT" --stale-days 30 2>&1)" || rc3=$?
[[ "$rc3" -eq 1 ]] || fail "Test 3: stale entry should cause exit 1, got exit $rc3"
echo "$out3" | grep -qi "CHUMP_STALE_ENTRY" \
    || fail "Test 3: output should mention CHUMP_STALE_ENTRY; got: $out3"
pass "Test 3: synthetic stale entry (31d absence) correctly flagged, exit 1"

# ── Test 4: ambient event emitted with required fields ─────────────────────────
[[ -f "$FAKE_AMBIENT" ]] || fail "Test 4: ambient.jsonl should exist after stale detection"
grep -q '"kind":"allowlist_stale_entry"' "$FAKE_AMBIENT" \
    || fail "Test 4: ambient.jsonl missing kind=allowlist_stale_entry; content: $(cat "$FAKE_AMBIENT")"
grep '"kind":"allowlist_stale_entry"' "$FAKE_AMBIENT" | grep -q '"entry"' \
    || fail "Test 4: allowlist_stale_entry event missing 'entry' field"
grep '"kind":"allowlist_stale_entry"' "$FAKE_AMBIENT" | grep -q '"file"' \
    || fail "Test 4: allowlist_stale_entry event missing 'file' field"
grep '"kind":"allowlist_stale_entry"' "$FAKE_AMBIENT" | grep -q '"days_since_seen"' \
    || fail "Test 4: allowlist_stale_entry event missing 'days_since_seen' field"
pass "Test 4: kind=allowlist_stale_entry emitted with entry/file/days_since_seen fields"

# ── Test 5: exit 0 when no stale entries ─────────────────────────────────────
rm -f "$FAKE_STATE" "$FAKE_AMBIENT"
FAKE_RESERVED_PRESENT_ONLY="$TMP/reserved-present-only.txt"
cat > "$FAKE_RESERVED_PRESENT_ONLY" <<'EOF'
CHUMP_PRESENT_ENTRY  # reason: test fixture
EOF

rc5=0
env \
    CHUMP_LOCK_DIR="$FAKE_LOCK" \
    CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" \
    CHUMP_ALLOWLIST_STATE="$FAKE_STATE" \
    CHUMP_ALLOWLIST_RESERVED="$FAKE_RESERVED_PRESENT_ONLY" \
    CHUMP_ALLOWLIST_ENVVARS="$FAKE_ENVVARS" \
    CHUMP_ALLOWLIST_CODE_ROOT="$FAKE_CODE" \
    CHUMP_AUDIT_ALLOWLIST_STALENESS=1 \
    bash "$AUDIT_SCRIPT" --stale-days 30 >/dev/null 2>&1 || rc5=$?
[[ "$rc5" -eq 0 ]] || fail "Test 5: no-stale scenario should exit 0, got exit $rc5"
pass "Test 5: exit 0 when no stale entries (exit 1 verified in Test 3)"

# ── Test 6: --dry-run suppresses state write and ambient emit ─────────────────
rm -f "$FAKE_AMBIENT"
# Re-inject backdated state.
cat > "$FAKE_STATE" <<STATE
{
  "event-registry-reserved.txt:CHUMP_STALE_ENTRY": {
    "last_seen": null,
    "absent_since": "$ABSENT_SINCE"
  }
}
STATE
STATE_MTIME_BEFORE="$(python3 -c "import os; print(os.stat('$FAKE_STATE').st_mtime)" 2>/dev/null)"

rc6=0
_audit_env bash "$AUDIT_SCRIPT" --dry-run --stale-days 30 >/dev/null 2>&1 || rc6=$?
[[ "$rc6" -eq 1 ]] || fail "Test 6: --dry-run with stale entries should still exit 1, got exit $rc6"

# Ambient must NOT have the event written under --dry-run.
if [[ -f "$FAKE_AMBIENT" ]] && grep -q '"kind":"allowlist_stale_entry"' "$FAKE_AMBIENT"; then
    fail "Test 6: --dry-run must NOT emit allowlist_stale_entry to ambient.jsonl"
fi

STATE_MTIME_AFTER="$(python3 -c "import os; print(os.stat('$FAKE_STATE').st_mtime)" 2>/dev/null)"
[[ "$STATE_MTIME_BEFORE" == "$STATE_MTIME_AFTER" ]] \
    || fail "Test 6: --dry-run must NOT update the state file mtime"
pass "Test 6: --dry-run suppresses ambient emit and state write (still exits 1 on stale)"

# ── AC #6: event-registry-reserved.txt contains the new kind ─────────────────
REGISTRY_RESERVED="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"
grep -q "allowlist_stale_entry" "$REGISTRY_RESERVED" \
    || fail "AC #6: allowlist_stale_entry must be in scripts/ci/event-registry-reserved.txt"
pass "AC #6: allowlist_stale_entry present in event-registry-reserved.txt"

echo ""
echo "All INFRA-1868 audit-allowlist-staleness checks passed (7/7)."
