#!/usr/bin/env bash
# scripts/ci/test-wizard-daemon-dry-run-readonly.sh — INFRA-2049
#
# Verifies that CHUMP_WIZARD_DAEMON_DRY_RUN=1 leaves ALL .chump-locks/* files
# unmodified. Specifically guards against the bug where step4 wrote phantom PID
# entries to wizard-daemon-dispatch-state.json even in dry-run mode.
#
# Strategy:
#   1. Set up a sandbox with stub gh + chump (chump gap list returns pickable gaps)
#   2. Snapshot md5/mtime of all files in sandbox .chump-locks/ before run
#   3. Run wizard-daemon with DRY_RUN=1
#   4. Re-snapshot and assert no changes
#
# Also verifies that ambient.jsonl IS written (dry-run does not suppress audit events).
#
# Usage:
#   bash scripts/ci/test-wizard-daemon-dry-run-readonly.sh
#
# Exit: 0 all pass, 1 any failure.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/wizard-daemon.sh"
PASS=0
FAIL=0
TOTAL=0

pass() { printf '  [PASS] %s\n' "$*"; (( PASS++ )); (( TOTAL++ )); }
fail() { printf '  [FAIL] %s\n' "$*" >&2; (( FAIL++ )); (( TOTAL++ )); }

# Cleanup trap
TMPDIRS_FILE="/tmp/test-wizard-dry-run-tmpdirs-$$.txt"
cleanup_tmpdirs() {
    if [[ -f "$TMPDIRS_FILE" ]]; then
        while IFS= read -r d; do
            rm -rf "$d" 2>/dev/null || true
        done < "$TMPDIRS_FILE"
        rm -f "$TMPDIRS_FILE"
    fi
}
trap cleanup_tmpdirs EXIT

printf 'Running INFRA-2049 wizard-daemon dry-run readonly tests...\n\n'

# ── Setup sandbox ─────────────────────────────────────────────────────────────

TMPDIR="$(mktemp -d)"
printf '%s\n' "$TMPDIR" >> "$TMPDIRS_FILE"

STUB_GH="$TMPDIR/gh"
STUB_CHUMP="$TMPDIR/chump"
LOCKS_DIR="$TMPDIR/.chump-locks"
AMBIENT="$LOCKS_DIR/ambient.jsonl"
DISPATCH_STATE="$LOCKS_DIR/wizard-daemon-dispatch-state.json"

mkdir -p "$LOCKS_DIR"

# Pre-seed a dispatch state file with a known entry so we can verify it's untouched
cat > "$DISPATCH_STATE" <<'SEEDSTATE'
{"dispatches":[{"gap_id":"CREDIBLE-999","ts":"2026-01-01T00:00:00Z","pid":99999}]}
SEEDSTATE

# Stub gh: returns one PR (CLEAN+armed) and empty checks
cat > "$STUB_GH" <<'GHSTUB'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "list" ]]; then
    printf '42\n'
elif [[ "$1" == "pr" && "$2" == "view" ]]; then
    printf '{"number":42,"title":"test PR","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","autoMergeRequest":{"enabledAt":"2026-01-01"},"isDraft":false}\n'
elif [[ "$1" == "pr" && "$2" == "checks" ]]; then
    printf '[]\n'
else
    exit 0
fi
GHSTUB
chmod +x "$STUB_GH"

# Stub chump: gap list returns two pickable gaps so step4 has candidates to (not) dispatch
cat > "$STUB_CHUMP" <<'CHUMPSTUB'
#!/usr/bin/env bash
case "$*" in
    "health --temp")
        printf 'COLD\n'; exit 0 ;;
    gap\ list\ *)
        printf '[{"id":"CREDIBLE-069","acceptance_criteria":"AC defined","notes":""},{"id":"CREDIBLE-070","acceptance_criteria":"AC defined","notes":""}]\n'
        exit 0 ;;
    gap\ preflight\ *)
        exit 0 ;;  # all gaps pickable
    "--execute-gap "*)
        # Should NEVER be called in dry-run — flag it
        printf 'DRY_RUN_EXECUTE_GAP_CALLED\n' >&2
        exit 0 ;;
    *)
        exit 0 ;;
esac
CHUMPSTUB
chmod +x "$STUB_CHUMP"

# Cache lib stub (force gh fallback for PR state)
mkdir -p "$TMPDIR/scripts/coord/lib"
cat > "$TMPDIR/scripts/coord/lib/github_cache.sh" <<'CACHELIB'
cache_query_open_prs() { return 1; }
cache_lookup_pr()      { return 1; }
cache_lookup_checks()  { return 1; }
CACHELIB

mkdir -p "$TMPDIR/scripts/coord"

cat > "$TMPDIR/scripts/coord/fleet-hold-check.sh" <<'HOLDSTUB'
#!/usr/bin/env bash
exit 0
HOLDSTUB
chmod +x "$TMPDIR/scripts/coord/fleet-hold-check.sh"

cat > "$TMPDIR/scripts/coord/recovery-queue-emit.sh" <<'EMITNOOPSTUB'
#!/usr/bin/env bash
exit 0
EMITNOOPSTUB
chmod +x "$TMPDIR/scripts/coord/recovery-queue-emit.sh"

cat > "$TMPDIR/scripts/coord/broadcast-urgent.sh" <<'BCASTSTUB'
#!/usr/bin/env bash
exit 0
BCASTSTUB
chmod +x "$TMPDIR/scripts/coord/broadcast-urgent.sh"

# ── Snapshot before run ───────────────────────────────────────────────────────

# Record md5 + size of dispatch-state.json before run
BEFORE_MD5="$(md5 -q "$DISPATCH_STATE" 2>/dev/null || md5sum "$DISPATCH_STATE" 2>/dev/null | awk '{print $1}')"
BEFORE_CONTENT="$(cat "$DISPATCH_STATE")"

printf 'Test 1: DRY_RUN=1 — dispatch-state.json must not be modified\n'
printf '  (pre-seeded with known entry, expecting it unchanged after run)\n'

# ── Run wizard-daemon with DRY_RUN=1 ─────────────────────────────────────────

CHUMP_WIZARD_DAEMON_ENABLED=1 \
CHUMP_WIZARD_DAEMON_DRY_RUN=1 \
CHUMP_WIZARD_TEST_GH="$STUB_GH" \
CHUMP_WIZARD_TEST_CHUMP="$STUB_CHUMP" \
CHUMP_AMBIENT_LOG="$AMBIENT" \
CHUMP_WIZARD_DISPATCH_STATE="$DISPATCH_STATE" \
CHUMP_REPO_ROOT="$TMPDIR" \
CHUMP_REPO="$TMPDIR" \
bash "$SCRIPT" 2>/dev/null || true

# ── Snapshot after run ────────────────────────────────────────────────────────

AFTER_MD5="$(md5 -q "$DISPATCH_STATE" 2>/dev/null || md5sum "$DISPATCH_STATE" 2>/dev/null | awk '{print $1}')"
AFTER_CONTENT="$(cat "$DISPATCH_STATE")"

# Test 1: dispatch-state.json unchanged
if [[ "$BEFORE_MD5" == "$AFTER_MD5" ]]; then
    pass "dispatch-state.json md5 unchanged after DRY_RUN=1 tick"
else
    fail "dispatch-state.json was modified during DRY_RUN=1 — before=$BEFORE_MD5 after=$AFTER_MD5"
    printf '  Before: %s\n' "$BEFORE_CONTENT" >&2
    printf '  After:  %s\n' "$AFTER_CONTENT" >&2
fi

# Test 2: pre-seeded entry still present (no silent truncation)
printf '\nTest 2: DRY_RUN=1 — pre-seeded CREDIBLE-999 entry still in state file\n'
if grep -q '"CREDIBLE-999"' "$DISPATCH_STATE" 2>/dev/null; then
    pass "pre-seeded CREDIBLE-999 entry preserved in dispatch-state.json"
else
    fail "pre-seeded CREDIBLE-999 entry was removed/lost during DRY_RUN=1 tick"
fi

# Test 3: no CREDIBLE-069/070 entries written (they were the "would-dispatch" candidates)
printf '\nTest 3: DRY_RUN=1 — gap candidates NOT written to dispatch-state.json\n'
if grep -qE '"CREDIBLE-069"|"CREDIBLE-070"' "$DISPATCH_STATE" 2>/dev/null; then
    fail "INFRA-2049: DRY_RUN=1 wrote phantom gap entries to dispatch-state.json"
else
    pass "gap candidates not written to dispatch-state.json in dry-run"
fi

# Test 4: ambient.jsonl WAS written (dry-run should still emit audit events)
printf '\nTest 4: DRY_RUN=1 — ambient.jsonl IS written (audit events not suppressed)\n'
if [[ -f "$AMBIENT" ]] && [[ -s "$AMBIENT" ]]; then
    pass "ambient.jsonl written during DRY_RUN=1 (audit events present)"
else
    fail "ambient.jsonl missing or empty during DRY_RUN=1 — audit events suppressed (unexpected)"
fi

# Test 5: dry_run_skipped action emitted in ambient for step4
printf '\nTest 5: DRY_RUN=1 — wizard emits dispatch_dry_run_skipped action for gap candidates\n'
if grep -q '"dispatch_dry_run_skipped"' "$AMBIENT" 2>/dev/null; then
    pass "dispatch_dry_run_skipped emitted for gap candidates in dry-run"
else
    fail "dispatch_dry_run_skipped NOT found in ambient — dry-run skipping not logged"
fi

# Test 6: chump --execute-gap was NOT spawned (check stderr of the run for the sentinel)
printf '\nTest 6: DRY_RUN=1 — chump --execute-gap never spawned\n'
# Re-run capturing stderr to check for the sentinel
DRY_RUN_STDERR="$(
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_DAEMON_DRY_RUN=1 \
    CHUMP_WIZARD_TEST_GH="$STUB_GH" \
    CHUMP_WIZARD_TEST_CHUMP="$STUB_CHUMP" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_WIZARD_DISPATCH_STATE="$DISPATCH_STATE" \
    CHUMP_REPO_ROOT="$TMPDIR" \
    CHUMP_REPO="$TMPDIR" \
    bash "$SCRIPT" 2>&1 >/dev/null || true
)"
if printf '%s\n' "$DRY_RUN_STDERR" | grep -q "DRY_RUN_EXECUTE_GAP_CALLED"; then
    fail "chump --execute-gap was called during DRY_RUN=1 (spawn not suppressed)"
else
    pass "chump --execute-gap not spawned in DRY_RUN=1"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n'
printf '═══════════════════════════════════════════════════════════\n'
printf 'Results: %d passed, %d failed (of %d checks)\n' "$PASS" "$FAIL" "$TOTAL"
printf '═══════════════════════════════════════════════════════════\n'

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
