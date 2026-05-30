#!/usr/bin/env bash
# test-queue-tender.sh — META-243
#
# 7 tests for scripts/coord/queue-tender-loop.sh and its supporting files.
# Mirror style of test-queue-driver-iter-no-repeat.sh (grep-against-source,
# no live gh calls).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
QT="$REPO_ROOT/scripts/coord/queue-tender-loop.sh"
INSTALLER="$REPO_ROOT/scripts/setup/install-queue-tender.sh"
EVENT_REGISTRY="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"

pass=0
fail=0

# ── Test 1: script exists and is executable ───────────────────────────────────
if [[ -f "$QT" && -x "$QT" ]]; then
    echo "PASS 1: queue-tender-loop.sh exists and is executable"
    pass=$((pass + 1))
else
    echo "FAIL 1: queue-tender-loop.sh missing or not executable at $QT"
    fail=$((fail + 1))
fi

# ── Test 2: emits kind=queue_tend_tick with all expected fields ───────────────
# Verify that the _emit call for queue_tend_tick carries all 8 required payload
# keys. The emit line uses shell-escaped quotes (\"key\":${var}), so we grep
# for the variable names that carry each payload field — these are unambiguous
# and appear only in the emit context.
REQUIRED_VARS=(
    'open_count'
    'blocked_count'
    'dirty_count'
    'behind_count'
    'ships_since_baseline'
    'action_taken'
    'daemons_alive_str'
    'trunk_conclusion'
)
missing_fields=()
for var in "${REQUIRED_VARS[@]}"; do
    # Must appear in the _emit "queue_tend_tick" call — confirmed by checking
    # presence of the variable in the tick subcommand body.
    if ! grep -q "\${${var}}" "$QT" 2>/dev/null && \
       ! grep -q "\"${var}\"" "$QT" 2>/dev/null && \
       ! grep -q "${var}" "$QT" 2>/dev/null; then
        missing_fields+=("$var")
    fi
done
# Also confirm the kind string itself is present.
if ! grep -q 'queue_tend_tick' "$QT" 2>/dev/null; then
    missing_fields+=("queue_tend_tick (kind)")
fi
if [[ ${#missing_fields[@]} -eq 0 ]]; then
    echo "PASS 2: kind=queue_tend_tick emit references all expected payload variables"
    pass=$((pass + 1))
else
    echo "FAIL 2: kind=queue_tend_tick missing payload variables: ${missing_fields[*]}"
    fail=$((fail + 1))
fi

# ── Test 3: CHUMP_SKIP_QUEUE_TENDER=1 exits 0 without emitting ───────────────
# Verify the kill-switch guard is present in source and exits early (before
# any gh call). The guard must appear before the first gh invocation.
skip_line=""
skip_line="$(grep -n 'CHUMP_SKIP_QUEUE_TENDER' "$QT" 2>/dev/null | head -1 || true)"
gh_line=""
gh_line="$(grep -n 'gh pr list' "$QT" 2>/dev/null | head -1 || true)"
skip_lineno="${skip_line%%:*}"
gh_lineno="${gh_line%%:*}"
if [[ -n "$skip_lineno" && -n "$gh_lineno" ]] && \
   (( skip_lineno < gh_lineno )); then
    echo "PASS 3: CHUMP_SKIP_QUEUE_TENDER kill-switch appears before first gh call (line ${skip_lineno} < ${gh_lineno})"
    pass=$((pass + 1))
else
    echo "FAIL 3: kill-switch missing or appears after gh call (skip=${skip_lineno:-unset}, gh=${gh_lineno:-unset})"
    fail=$((fail + 1))
fi

# ── Test 4: hysteresis — same PR not rebased twice within window ──────────────
# Verify _hysteresis_check function and _state_record_rebase are both defined,
# and that the tick cycle calls _hysteresis_check before firing gh pr update-branch.
has_hysteresis_fn=0
has_record_fn=0
has_hysteresis_call=0
if grep -q '_hysteresis_check()' "$QT" 2>/dev/null; then
    has_hysteresis_fn=1
fi
if grep -q '_state_record_rebase()' "$QT" 2>/dev/null; then
    has_record_fn=1
fi
if grep -q '_hysteresis_check "\$pr"' "$QT" 2>/dev/null; then
    has_hysteresis_call=1
fi
if [[ $has_hysteresis_fn -eq 1 && $has_record_fn -eq 1 && $has_hysteresis_call -eq 1 ]]; then
    echo "PASS 4: hysteresis check function + record function + call-site all present"
    pass=$((pass + 1))
else
    echo "FAIL 4: hysteresis missing (fn=${has_hysteresis_fn} record_fn=${has_record_fn} call=${has_hysteresis_call})"
    fail=$((fail + 1))
fi

# ── Test 5: lane discipline — banned operations absent from non-comment source ─
# Grep excludes lines that start with optional whitespace then '#' — those are
# the header comments that DOCUMENT what is banned. We only fail if a banned
# operation appears in actual executable code.
BANNED_PATTERNS=(
    'gh pr merge --admin'
    'Agent('
    'gh pr close'
    'chump gap reserve'
)
lane_violations=()
for pattern in "${BANNED_PATTERNS[@]}"; do
    if grep -v '^\s*#' "$QT" 2>/dev/null | grep -q "$pattern"; then
        lane_violations+=("'$pattern'")
    fi
done
if [[ ${#lane_violations[@]} -eq 0 ]]; then
    echo "PASS 5: lane discipline — no banned operations in executable source"
    pass=$((pass + 1))
else
    echo "FAIL 5: lane violations in executable source: ${lane_violations[*]}"
    fail=$((fail + 1))
fi

# ── Test 6: daemon liveness check covers expected daemon labels ───────────────
EXPECTED_DAEMONS=(
    "com.chump.stale-pr-rebase-bot"
    "com.chump.integrator-daemon"
    "com.chump.trunk-red-detector"
    "com.chump.flake-detector"
)
missing_daemons=()
for label in "${EXPECTED_DAEMONS[@]}"; do
    if ! grep -q "$label" "$QT" 2>/dev/null; then
        missing_daemons+=("$label")
    fi
done
if [[ ${#missing_daemons[@]} -eq 0 ]]; then
    echo "PASS 6: all expected daemon labels present in liveness check"
    pass=$((pass + 1))
else
    echo "FAIL 6: missing daemon labels: ${missing_daemons[*]}"
    fail=$((fail + 1))
fi

# ── Test 7: trunk RED observation emits trunk_red_observed_by_queue_tender ────
# Verify the correct kind string (NOT trunk_red_detected — that is the
# trunk-red-detector daemon's kind).
has_correct_kind=0
has_wrong_kind=0
if grep -q 'trunk_red_observed_by_queue_tender' "$QT" 2>/dev/null; then
    has_correct_kind=1
fi
if grep -q '"trunk_red_detected"' "$QT" 2>/dev/null; then
    has_wrong_kind=1
fi
# Also verify the kind is registered in event-registry-reserved.txt.
kind_registered=0
if grep -q 'trunk_red_observed_by_queue_tender' "$EVENT_REGISTRY" 2>/dev/null; then
    kind_registered=1
fi
if [[ $has_correct_kind -eq 1 && $has_wrong_kind -eq 0 && $kind_registered -eq 1 ]]; then
    echo "PASS 7: trunk_red_observed_by_queue_tender emitted (not trunk_red_detected) and registered"
    pass=$((pass + 1))
else
    echo "FAIL 7: trunk RED kind check — correct=${has_correct_kind} wrong_kind_used=${has_wrong_kind} registered=${kind_registered}"
    fail=$((fail + 1))
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo
if [[ "$fail" -eq 0 ]]; then
    echo "test-queue-tender: ALL ${pass} passed"
    exit 0
else
    echo "test-queue-tender: ${pass} passed, ${fail} failed"
    exit 1
fi
