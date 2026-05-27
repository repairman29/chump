#!/usr/bin/env bash
# scripts/ci/test-wizard-daemon-merge-state-parse.sh — INFRA-2042
#
# Tests that wizard-daemon step1 correctly handles all mergeStateStatus variants:
#   UNKNOWN  → emits wizard_classify_deferred, does NOT enqueue for step2
#   BLOCKED  → classifies BLOCKED+real-fails, enqueues for step2/step3
#   CLEAN    → classifies CLEAN+armed (if auto-merge armed), passes through
#   DIRTY    → classifies DIRTY (no auto-merge), no step2 action
#
# Uses a synthetic gh stub via $PATH override (CHUMP_WIZARD_TEST_GH).
# Uses a synthetic chump stub (CHUMP_WIZARD_TEST_CHUMP).
# Reads ambient.jsonl to verify event emission.
#
# Usage:
#   bash scripts/ci/test-wizard-daemon-merge-state-parse.sh
#
# Exit: 0 all pass, 1 any failure.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/wizard-daemon.sh"
PASS=0
FAIL=0
TOTAL=0

# ── Helpers ───────────────────────────────────────────────────────────────────

pass() { printf '  [PASS] %s\n' "$*"; (( PASS++ )); (( TOTAL++ )); }
fail() { printf '  [FAIL] %s\n' "$*" >&2; (( FAIL++ )); (( TOTAL++ )); }

# Run wizard-daemon with stub gh + chump in a temp sandbox.
# $1 = pr_json to return from stub gh pr view
# Prints the ambient.jsonl content after the run.
run_wizard_with_pr_json() {
    local pr_json="$1"

    local tmpdir; tmpdir="$(mktemp -d)"
    local stub_gh="$tmpdir/gh"
    local stub_chump="$tmpdir/chump"
    local ambient="$tmpdir/ambient.jsonl"

    # Stub gh: returns the fixture PR json for 'pr view', empty for 'pr list'
    cat > "$stub_gh" <<GHSTUB
#!/usr/bin/env bash
# Stub gh binary — INFRA-2042 test fixture
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then
    # Return PR number 42
    printf '42\n'
elif [[ "\$1" == "pr" && "\$2" == "view" ]]; then
    printf '%s\n' '$pr_json'
elif [[ "\$1" == "pr" && "\$2" == "checks" ]]; then
    # No checks (simplifies test scope to classification only)
    printf '[]\n'
else
    exit 0
fi
GHSTUB
    chmod +x "$stub_gh"

    # Stub chump: no-op for health --temp, gap list, preflight
    cat > "$stub_chump" <<CHUMPSTUB
#!/usr/bin/env bash
# Stub chump binary — INFRA-2042 test fixture
case "\$*" in
    "health --temp") printf 'COLD\n'; exit 0 ;;
    "gap list "*)    printf '[]\n';   exit 0 ;;
    "gap preflight "*)                exit 1 ;; # nothing pickable
    *)                                exit 0 ;;
esac
CHUMPSTUB
    chmod +x "$stub_chump"

    # Minimal cache lib stub — placed where wizard-daemon will find it via REPO_ROOT
    # wizard-daemon constructs: LIB_CACHE="$REPO_ROOT/scripts/coord/lib/github_cache.sh"
    # We point CHUMP_REPO_ROOT at tmpdir so the stub cache lib is picked up,
    # preventing the real SQLite cache from returning live PRs.
    mkdir -p "$tmpdir/scripts/coord/lib"
    cat > "$tmpdir/scripts/coord/lib/github_cache.sh" <<'CACHELIB'
# Stub github_cache.sh — INFRA-2042 test fixture; returns empty to force gh fallback
cache_query_open_prs() { return 1; }
cache_lookup_pr()      { return 1; }
cache_lookup_checks()  { return 1; }
CACHELIB

    # Also stub fleet-hold-check.sh (returns OK = no hold)
    mkdir -p "$tmpdir/scripts/coord"
    cat > "$tmpdir/scripts/coord/fleet-hold-check.sh" <<'HOLDSTUB'
#!/usr/bin/env bash
exit 0  # no hold active
HOLDSTUB
    chmod +x "$tmpdir/scripts/coord/fleet-hold-check.sh"

    # Also stub recovery-queue-emit.sh (no-op)
    cat > "$tmpdir/scripts/coord/recovery-queue-emit.sh" <<'EMITNOOPSTUB'
#!/usr/bin/env bash
# no-op stub for test
exit 0
EMITNOOPSTUB
    chmod +x "$tmpdir/scripts/coord/recovery-queue-emit.sh"

    # Also stub broadcast-urgent.sh (no-op)
    cat > "$tmpdir/scripts/coord/broadcast-urgent.sh" <<'BCASTSTUB'
#!/usr/bin/env bash
exit 0
BCASTSTUB
    chmod +x "$tmpdir/scripts/coord/broadcast-urgent.sh"

    # Run wizard-daemon with test overrides
    # CHUMP_REPO_ROOT points to tmpdir so LIB_CACHE + helper scripts resolve to stubs
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_TEST_GH="$stub_gh" \
    CHUMP_WIZARD_TEST_CHUMP="$stub_chump" \
    CHUMP_AMBIENT_LOG="$ambient" \
    CHUMP_REPO_ROOT="$tmpdir" \
    CHUMP_REPO="$tmpdir" \
    bash "$SCRIPT" 2>/dev/null || true

    # Return ambient log path for inspection
    printf '%s\n' "$ambient"

    # Cleanup handled by caller via ambient path
    # (tmpdir left for caller to read ambient; caller should rm -rf)
    printf '%s\n' "$tmpdir" >> /tmp/test-wizard-tmpdirs-$$.txt
}

# shellcheck disable=SC2329  # invoked via trap EXIT below
cleanup_tmpdirs() {
    if [[ -f /tmp/test-wizard-tmpdirs-$$.txt ]]; then
        while IFS= read -r d; do
            rm -rf "$d" 2>/dev/null || true
        done < /tmp/test-wizard-tmpdirs-$$.txt
        rm -f /tmp/test-wizard-tmpdirs-$$.txt
    fi
}
trap cleanup_tmpdirs EXIT

printf 'Running INFRA-2042 wizard-daemon merge-state parse tests...\n\n'

# ── Test 1: UNKNOWN merge state → deferred (no step2 enqueue) ─────────────────
printf 'Test 1: UNKNOWN merge_state → wizard_classify_deferred emitted, no step2\n'

PR_UNKNOWN='{"number":42,"title":"test PR","mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","autoMergeRequest":null,"isDraft":false}'

ambient_path="$(run_wizard_with_pr_json "$PR_UNKNOWN" | head -1)"

if grep -q '"kind":"wizard_classify_deferred"' "$ambient_path" 2>/dev/null; then
    pass "wizard_classify_deferred emitted for UNKNOWN state"
else
    fail "wizard_classify_deferred NOT emitted for UNKNOWN state"
fi

# UNKNOWN should not trigger recovery_queue_emitted (step2)
if grep -q '"decision":"recovery_queue_emitted"' "$ambient_path" 2>/dev/null; then
    fail "step2 recovery_queue_emitted was triggered for UNKNOWN (should be skipped)"
else
    pass "step2 not triggered for UNKNOWN state"
fi

# UNKNOWN deferred event should carry pr and reason fields
if grep -q '"reason":"unknown_merge_state"' "$ambient_path" 2>/dev/null; then
    pass "wizard_classify_deferred carries reason=unknown_merge_state"
else
    fail "wizard_classify_deferred missing reason field"
fi

# ── Test 2: BLOCKED → enqueue for recovery (step2 fires) ─────────────────────
printf '\nTest 2: BLOCKED merge_state → BLOCKED+real-fails → step2 recovery_queue_emitted\n'

PR_BLOCKED='{"number":42,"title":"test PR","mergeable":"CONFLICTED","mergeStateStatus":"BLOCKED","autoMergeRequest":{"enabledAt":"2026-01-01"},"isDraft":false}'

ambient_path="$(run_wizard_with_pr_json "$PR_BLOCKED" | head -1)"

# Should classify as BLOCKED+real-fails
if grep -q '"pr_class":"BLOCKED+real-fails"' "$ambient_path" 2>/dev/null; then
    pass "BLOCKED state → classified as BLOCKED+real-fails"
else
    fail "BLOCKED state NOT classified as BLOCKED+real-fails"
fi

# Should NOT emit wizard_classify_deferred
if grep -q '"kind":"wizard_classify_deferred"' "$ambient_path" 2>/dev/null; then
    fail "wizard_classify_deferred incorrectly emitted for BLOCKED state"
else
    pass "wizard_classify_deferred NOT emitted for BLOCKED (correct)"
fi

# ── Test 3: CLEAN + auto-merge armed → CLEAN+armed pass-through ───────────────
printf '\nTest 3: CLEAN merge_state + auto_merge armed → CLEAN+armed (no recovery)\n'

PR_CLEAN='{"number":42,"title":"test PR","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","autoMergeRequest":{"enabledAt":"2026-01-01"},"isDraft":false}'

ambient_path="$(run_wizard_with_pr_json "$PR_CLEAN" | head -1)"

if grep -q '"pr_class":"CLEAN+armed"' "$ambient_path" 2>/dev/null; then
    pass "CLEAN+auto-merge → classified as CLEAN+armed"
else
    fail "CLEAN+auto-merge NOT classified as CLEAN+armed"
fi

# Should NOT emit wizard_classify_deferred
if grep -q '"kind":"wizard_classify_deferred"' "$ambient_path" 2>/dev/null; then
    fail "wizard_classify_deferred incorrectly emitted for CLEAN state"
else
    pass "wizard_classify_deferred NOT emitted for CLEAN (correct)"
fi

# Should NOT emit step2 recovery (CLEAN+armed is not a recovery case)
if grep -q '"decision":"recovery_queue_emitted"' "$ambient_path" 2>/dev/null; then
    fail "step2 recovery_queue_emitted incorrectly triggered for CLEAN+armed"
else
    pass "step2 not triggered for CLEAN+armed"
fi

# ── Test 4: CLEAN merge state but no auto-merge → pr_class=DIRTY, no enqueue ──
# NOTE: mergeStateStatus=DIRTY (GitHub API enum) hits BLOCKED+real-fails branch.
# The internal pr_class=DIRTY is reached when auto_merge=0 AND no other condition
# matches (e.g. mergeStateStatus=CLEAN but autoMergeRequest is null).
printf '\nTest 4: CLEAN merge_state + no auto_merge → pr_class=DIRTY (unqueued), no step2\n'

PR_CLEAN_NO_AUTOMERGE='{"number":42,"title":"test PR","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","autoMergeRequest":null,"isDraft":false}'

ambient_path="$(run_wizard_with_pr_json "$PR_CLEAN_NO_AUTOMERGE" | head -1)"

if grep -q '"pr_class":"DIRTY"' "$ambient_path" 2>/dev/null; then
    pass "CLEAN+no-auto-merge → classified as DIRTY (not queued)"
else
    fail "CLEAN+no-auto-merge NOT classified as DIRTY"
fi

# DIRTY internal class should not trigger step2
if grep -q '"decision":"recovery_queue_emitted"' "$ambient_path" 2>/dev/null; then
    fail "step2 recovery_queue_emitted incorrectly triggered for DIRTY class"
else
    pass "step2 not triggered for DIRTY class"
fi

# Should NOT emit wizard_classify_deferred
if grep -q '"kind":"wizard_classify_deferred"' "$ambient_path" 2>/dev/null; then
    fail "wizard_classify_deferred incorrectly emitted for DIRTY class"
else
    pass "wizard_classify_deferred NOT emitted for DIRTY class (correct)"
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
