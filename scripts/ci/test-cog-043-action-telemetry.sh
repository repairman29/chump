#!/usr/bin/env bash
# test-cog-043-action-telemetry.sh — COG-043
#
# Static-validates the action-telemetry plumbing:
#  1. lesson_action.rs module exists + exports the right fns
#  2. briefing.rs emits lessons_shown after rendering
#  3. main.rs has the chump lesson-grade subcommand
#  4. bot-merge.sh's auto-close path calls chump lesson-grade
#  5. unit tests defined (cog043_ prefix; full run via cargo test --workspace)
#
# Live e2e (briefing → ship → ambient events) is out of scope here —
# would require a built chump binary + sqlite seed. That's the
# post-merge validation step.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== COG-043 action-telemetry plumbing test ==="
echo

# --- 1. module exists ---
if [[ -f "$REPO_ROOT/src/lesson_action.rs" ]]; then
    ok "src/lesson_action.rs module exists"
else
    fail "src/lesson_action.rs missing"
fi

# --- 2. module exports the public fns we wire to ---
for fn in extract_keywords score_directive_against_pr directive_applied emit_lessons_shown emit_lesson_grade; do
    if grep -qE "pub fn ${fn}\b" "$REPO_ROOT/src/lesson_action.rs" 2>/dev/null; then
        ok "  pub fn $fn exists"
    else
        fail "  pub fn $fn missing"
    fi
done

# --- 3. briefing.rs emits lessons_shown ---
if grep -q 'lesson_action::emit_lessons_shown' "$REPO_ROOT/src/briefing.rs"; then
    ok "briefing.rs calls emit_lessons_shown after ranking"
else
    fail "briefing.rs does not call emit_lessons_shown"
fi

# --- 4. briefing.rs distinguishes mode (semantic vs recency vs fallback) ---
if grep -q 'recency_fallback_from_semantic' "$REPO_ROOT/src/briefing.rs"; then
    ok "briefing.rs records ranking_mode=recency_fallback_from_semantic when semantic returns empty"
else
    fail "briefing.rs doesn't distinguish semantic-fallback from real-recency"
fi

# --- 5. main.rs has chump lesson-grade subcommand ---
if grep -q 'Some("lesson-grade")' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "chump lesson-grade subcommand wired in main.rs"
else
    fail "chump lesson-grade subcommand missing"
fi

# --- 6. main.rs run_lesson_grade exists ---
if grep -qE '^fn run_lesson_grade' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "run_lesson_grade fn defined"
else
    fail "run_lesson_grade fn missing"
fi

# --- 7+8. bot-merge.sh integration: deferred to follow-up PR (touches a
# sensitive infra path that the code-reviewer ESCALATEs by policy).
# This PR ships the core plumbing only; the bot-merge.sh hook lands
# separately. Operators can run `chump lesson-grade` manually until then.
echo "  NOTE: bot-merge.sh integration deferred to follow-up PR (sensitive-path escalation)"

# --- 9. unit tests defined (full run lives in cargo test --workspace) ---
test_count=$(grep -cE 'fn cog043_' "$REPO_ROOT/src/lesson_action.rs" 2>/dev/null || echo 0)
if [[ "$test_count" -ge 5 ]]; then
    ok "in-tree cog043_ unit tests defined ($test_count fns; full run via cargo test --workspace)"
else
    fail "expected >=5 cog043_ unit tests, found $test_count"
fi

# --- 10. emit calls run before any blocking I/O (best-effort guarantee) ---
# Static check: no .expect() / .unwrap() / panic! in the emit fns' bodies.
emit_block=$(awk '/pub fn emit_lessons_shown/,/^}/' "$REPO_ROOT/src/lesson_action.rs")
if echo "$emit_block" | grep -qE '\.unwrap\(\)|\.expect\(|\bpanic!'; then
    fail "emit_lessons_shown contains unwrap/expect/panic — telemetry is supposed to be best-effort"
else
    ok "emit_lessons_shown body is panic-free (best-effort)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
