#!/usr/bin/env bash
# scripts/ci/test-per-worktree-target-guard.sh — RESILIENT-001
#
# Validates per-worktree target-dir stale binary guard:
#  - _check_binary_freshness() present in worker.sh
#  - stale_binary_detected kind emitted when binary is older than threshold
#  - CHUMP_BINARY_MAX_AGE_SECS honored
#  - stale_binary_detected registered in EVENT_REGISTRY.yaml

set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== RESILIENT-001: per-worktree stale binary guard ==="
echo

WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

# 1. _check_binary_freshness function present
if grep -q '_check_binary_freshness' "$WORKER" 2>/dev/null; then
    ok "worker.sh: _check_binary_freshness() defined"
else
    fail "worker.sh: _check_binary_freshness() missing"
fi

# 2. stale_binary_detected kind emitted
if grep -q 'stale_binary_detected' "$WORKER" 2>/dev/null; then
    ok "worker.sh: stale_binary_detected event emitted"
else
    fail "worker.sh: stale_binary_detected event missing"
fi

# 3. CHUMP_BINARY_MAX_AGE_SECS honored
if grep -q 'CHUMP_BINARY_MAX_AGE_SECS' "$WORKER" 2>/dev/null; then
    ok "worker.sh: CHUMP_BINARY_MAX_AGE_SECS env var honored"
else
    fail "worker.sh: CHUMP_BINARY_MAX_AGE_SECS not referenced"
fi

# 4. default threshold is 7200
if grep -q '7200' "$WORKER" 2>/dev/null; then
    ok "worker.sh: default 7200s (2h) threshold present"
else
    fail "worker.sh: 7200s default threshold missing"
fi

# 5. ambient log path written
if grep -q 'ambient.jsonl' "$WORKER" 2>/dev/null; then
    ok "worker.sh: writes to ambient.jsonl"
else
    fail "worker.sh: does not write to ambient.jsonl"
fi

# 6. kind registered in EVENT_REGISTRY.yaml
if grep -q 'stale_binary_detected' "$REGISTRY" 2>/dev/null; then
    ok "EVENT_REGISTRY.yaml: stale_binary_detected registered"
else
    fail "EVENT_REGISTRY.yaml: stale_binary_detected missing"
fi

# 7. fields_required includes age_secs
# Use -A8 to tolerate the effect_metric field inserted by INFRA-1371 schema v2,
# which adds one line between '- kind:' and subsequent fields.
if grep -A8 'stale_binary_detected' "$REGISTRY" 2>/dev/null | grep -q 'age_secs'; then
    ok "EVENT_REGISTRY.yaml: age_secs in fields_required"
else
    fail "EVENT_REGISTRY.yaml: age_secs missing from fields_required"
fi

# 8. guard is positioned before the main cycle loop
# The function call _check_binary_freshness must appear before "while :;"
_wf_line=$(grep -n '_check_binary_freshness$' "$WORKER" 2>/dev/null | tail -1 | cut -d: -f1)
_loop_line=$(grep -n '^cycle=0' "$WORKER" 2>/dev/null | head -1 | cut -d: -f1)
if [[ -n "$_wf_line" && -n "$_loop_line" && "$_wf_line" -lt "$_loop_line" ]]; then
    ok "worker.sh: guard runs before main dispatch loop"
else
    fail "worker.sh: guard not positioned before main loop (guard=$_wf_line loop=$_loop_line)"
fi

# ── Functional test: emit event on stale binary ───────────────────────────────

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT
mkdir -p "$TMPDIR_TEST/.chump-locks" "$TMPDIR_TEST/target/debug" "$TMPDIR_TEST/src"

# Create a "binary" with old mtime and a "source" with new mtime
touch -t 202001010000 "$TMPDIR_TEST/target/debug/chump"
touch "$TMPDIR_TEST/src/main.rs"  # current mtime

# Extract and run just the freshness check function
_freshness_fn=$(awk '/^_check_binary_freshness\(\)/,/^}$/' "$WORKER")

if bash -c "
REPO_ROOT='$TMPDIR_TEST'
CHUMP_BINARY_MAX_AGE_SECS=1
log() { :; }
$_freshness_fn
_check_binary_freshness
" 2>/dev/null; then
    if grep -q 'stale_binary_detected' "$TMPDIR_TEST/.chump-locks/ambient.jsonl" 2>/dev/null; then
        ok "stale binary: emits stale_binary_detected to ambient.jsonl"
    else
        fail "stale binary: no ambient event written"
    fi
else
    fail "stale binary: freshness check function failed to run"
fi

# 10. Non-stale binary: no event emitted
TMPDIR_TEST2=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST" "$TMPDIR_TEST2"' EXIT
mkdir -p "$TMPDIR_TEST2/.chump-locks" "$TMPDIR_TEST2/target/debug" "$TMPDIR_TEST2/src"
touch "$TMPDIR_TEST2/target/debug/chump"
touch -t 202001010000 "$TMPDIR_TEST2/src/main.rs"  # old source, fresh binary

bash -c "
REPO_ROOT='$TMPDIR_TEST2'
CHUMP_BINARY_MAX_AGE_SECS=7200
log() { :; }
$_freshness_fn
_check_binary_freshness
" 2>/dev/null || true

if ! grep -q 'stale_binary_detected' "$TMPDIR_TEST2/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "fresh binary: no ambient event emitted"
else
    fail "fresh binary: spurious stale_binary_detected event emitted"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
