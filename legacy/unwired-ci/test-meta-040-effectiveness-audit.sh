#!/usr/bin/env bash
# test-meta-040-effectiveness-audit.sh — META-040
#
# Static + functional test of the lesson-effectiveness audit. Exercises
# the classification logic against a synthetic ambient.jsonl so we get
# real signal without depending on telemetry that hasn't accumulated yet.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
AUDIT="$REPO_ROOT/scripts/eval/lesson-effectiveness-audit.py"

[[ -x "$AUDIT" ]] || { echo "FATAL: audit script missing"; exit 2; }

echo "=== META-040 lesson-effectiveness audit test ==="
echo

# --- 1. script is python3-importable ---
if python3 -c "import ast; ast.parse(open('$AUDIT').read())" 2>/dev/null; then
    ok "audit.py parses cleanly"
else
    fail "audit.py has syntax errors"
fi

# --- 2. functional: synthetic ambient → expected classification ---
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

FAKE="$TMPDIR_BASE/repo"
mkdir -p "$FAKE/.chump-locks" "$FAKE/docs/eval"
AMB="$FAKE/.chump-locks/ambient.jsonl"

# Synthesize:
# - "noisy" directive: shown 12 times, applied 0 times → prune
# - "useful" directive: shown 11 times, applied 8 times not_applied 2 → keep
# - "watched" directive: shown 10 times, applied 1 not_applied 9 → watch (10%)
# - "rare" directive: shown 3 times, applied 1 → insufficient_data
python3 - "$AMB" <<'PYEOF'
import json, sys
amb = sys.argv[1]
with open(amb, 'w') as f:
    # 12 lessons_shown that include the noisy + useful + watched + rare
    for _ in range(10):
        f.write(json.dumps({"kind":"lessons_shown","directives":["noisy directive","useful directive","watched directive"],"gap_id":"INFRA-X"}) + "\n")
    for _ in range(2):
        f.write(json.dumps({"kind":"lessons_shown","directives":["noisy directive","useful directive"],"gap_id":"INFRA-Y"}) + "\n")
    for _ in range(3):
        f.write(json.dumps({"kind":"lessons_shown","directives":["rare directive"],"gap_id":"COG-Z"}) + "\n")
    # Now grade events: useful applied 8x, not_applied 2x; watched applied 1x, not_applied 9x; rare applied 1x.
    # noisy gets graded with not_applied 5x (so n_graded=5, applied=0 → adoption=0)
    for _ in range(8):
        f.write(json.dumps({"kind":"lesson_applied","directive":"useful directive"}) + "\n")
    for _ in range(2):
        f.write(json.dumps({"kind":"lesson_not_applied","directive":"useful directive"}) + "\n")
    for _ in range(1):
        f.write(json.dumps({"kind":"lesson_applied","directive":"watched directive"}) + "\n")
    for _ in range(9):
        f.write(json.dumps({"kind":"lesson_not_applied","directive":"watched directive"}) + "\n")
    for _ in range(5):
        f.write(json.dumps({"kind":"lesson_not_applied","directive":"noisy directive"}) + "\n")
    for _ in range(1):
        f.write(json.dumps({"kind":"lesson_applied","directive":"rare directive"}) + "\n")
PYEOF

(
    cd "$FAKE"
    CHUMP_REPO="$FAKE" python3 "$AUDIT" 2>"$TMPDIR_BASE/stderr"
)

REPORT=$(ls "$FAKE"/docs/eval/lesson-effectiveness-*.md 2>/dev/null | head -1)
if [[ -z "$REPORT" ]]; then
    fail "audit did not produce a report"
    cat "$TMPDIR_BASE/stderr"
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

# --- 3. classification correctness ---
if grep -qE '## Prune candidates \(1\)' "$REPORT"; then
    ok "noisy directive classified as prune (n_shown=12, adoption=0%)"
else
    fail "noisy directive not classified as prune"
    grep -A1 "## Prune" "$REPORT" | head
fi

if grep -qE '## Effective lessons \(1\)' "$REPORT"; then
    ok "useful directive classified as keep (n_shown=12, adoption=80%)"
else
    fail "useful directive not classified as keep"
fi

if grep -qE '## Watch list \(1\)' "$REPORT"; then
    ok "watched directive classified as watch (n_shown=10, adoption=10%)"
else
    fail "watched directive not classified as watch"
fi

if grep -qE 'Insufficient data \(1\)' "$REPORT"; then
    ok "rare directive classified as insufficient_data (n_shown=3)"
else
    fail "rare directive not classified as insufficient_data"
fi

# --- 4. ambient summary event emitted ---
if grep -qE '"kind":[[:space:]]*"lessons_audit_run"' "$AMB"; then
    ok "lessons_audit_run summary event emitted to ambient.jsonl"
else
    fail "no lessons_audit_run summary event"
fi

if grep -qE '"kind":[[:space:]]*"lessons_pruned"' "$AMB"; then
    ok "lessons_pruned ALERT emitted for prune candidates"
else
    fail "no lessons_pruned ALERT"
fi

# --- 5. empty ambient → graceful (no crash, zero counts) ---
EMPTY_REPO="$TMPDIR_BASE/empty"
mkdir -p "$EMPTY_REPO/.chump-locks" "$EMPTY_REPO/docs/eval"
touch "$EMPTY_REPO/.chump-locks/ambient.jsonl"
(
    cd "$EMPTY_REPO"
    CHUMP_REPO="$EMPTY_REPO" python3 "$AUDIT" >/dev/null 2>&1
)
EMPTY_REPORT=$(ls "$EMPTY_REPO"/docs/eval/lesson-effectiveness-*.md 2>/dev/null | head -1)
if [[ -n "$EMPTY_REPORT" ]] && grep -qE 'keep=0 watch=0 prune=0 insufficient=0' "$EMPTY_REPORT"; then
    ok "empty ambient → graceful zero-state report (no crash)"
else
    fail "empty-ambient handling broken"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
