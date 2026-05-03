#!/usr/bin/env bash
# test-bot-merge-hot-file-warning.sh — regression test for INFRA-305.
#
# Verifies the hot-file rebase-loop expectation pre-emit:
#   1. BOT_MERGE_HOT_FILES constant exists near top of bot-merge.sh
#      (single source of truth, hand-curated).
#   2. emit_hot_file_warnings() function exists.
#   3. When the diff vs origin/main contains a hot file, the function
#      emits a stderr note AND appends a JSON event to ambient.jsonl.
#   4. When the diff contains no hot file, neither side fires.
#
# Run:
#   ./scripts/ci/test-bot-merge-hot-file-warning.sh
#
# Exits non-zero on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BM="$REPO_ROOT/scripts/coord/bot-merge.sh"

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-305 hot-file warning regression tests ==="
echo

# 1. The constant exists and lists at least the canonical hot files.
if grep -q '^BOT_MERGE_HOT_FILES=(' "$BM"; then
    ok "BOT_MERGE_HOT_FILES array constant present"
else
    fail "BOT_MERGE_HOT_FILES array constant missing"
fi

for must in ".github/workflows/ci.yml" "scripts/git-hooks/pre-commit" "CLAUDE.md"; do
    if grep -F -q "\"$must\"" "$BM"; then
        ok "BOT_MERGE_HOT_FILES contains $must"
    else
        fail "BOT_MERGE_HOT_FILES missing $must"
    fi
done

# 2. The emitter function exists.
if grep -q '^emit_hot_file_warnings()' "$BM"; then
    ok "emit_hot_file_warnings() function defined"
else
    fail "emit_hot_file_warnings() function missing"
fi

# 3. The arm-time call site exists (must run before gh pr merge --auto).
if awk '
    /emit_hot_file_warnings "\$TARGET_PR"/ { found=NR }
    /gh pr merge "\$TARGET_PR" --auto --squash/ { merge=NR }
    END { exit (found && merge && found < merge) ? 0 : 1 }
' "$BM"; then
    ok "emit_hot_file_warnings called before gh pr merge --auto --squash"
else
    fail "emit_hot_file_warnings is not called before the auto-merge arm step"
fi

# 4. Functional test: source the script in a controlled subshell harness.
# bot-merge.sh is set -euo pipefail and runs main flow at source-time, so
# we can't simply `source` it. Instead, run the function in a sandbox that
# extracts just the constant + function via bash heredoc.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

cd "$SANDBOX"
git init -q
git config user.email "test@example.com"
git config user.name "Test"
git config commit.gpgsign false

# Seed an "origin/main" baseline.
mkdir -p .github/workflows scripts/git-hooks
echo "baseline" > README.md
git add README.md
git -c init.defaultBranch=main commit -q -m "baseline"
git branch -M main
git update-ref refs/remotes/origin/main HEAD

# Simulate a feature branch that touches a hot file.
git checkout -q -b feature
echo "name: ci" > .github/workflows/ci.yml
git add .github/workflows/ci.yml
git commit -q -m "ci tweak"

# Extract the hot-file constant + function from the real script.
HARNESS="$SANDBOX/harness.sh"
{
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    # Pull the array literal.
    awk '/^BOT_MERGE_HOT_FILES=\(/,/^\)/' "$BM"
    echo
    # Pull the function body.
    awk '/^emit_hot_file_warnings\(\) \{/,/^\}/' "$BM"
    echo
    # Stub variables the function expects.
    cat <<'SHIM'
REMOTE="origin"
BASE_BRANCH="main"
LOCK_DIR="$SANDBOX/locks"
mkdir -p "$LOCK_DIR"
_BM_PID=$$
emit_hot_file_warnings "$1" "$2"
SHIM
} > "$HARNESS"
chmod +x "$HARNESS"

# Run with hot-file diff present.
HOT_OUT="$SANDBOX/hot.stderr"
SANDBOX="$SANDBOX" bash "$HARNESS" "1234" "INFRA-305" 2>"$HOT_OUT" >/dev/null

if grep -q "HOT FILE: .github/workflows/ci.yml" "$HOT_OUT"; then
    ok "stderr note printed for ci.yml hot edit"
else
    fail "stderr note NOT printed for ci.yml hot edit (got: $(cat "$HOT_OUT"))"
fi

if grep -q '"event":"bot_merge_hot_file"' "$SANDBOX/locks/ambient.jsonl" 2>/dev/null \
   && grep -q '"path":".github/workflows/ci.yml"' "$SANDBOX/locks/ambient.jsonl" \
   && grep -q '"gap_id":"INFRA-305"' "$SANDBOX/locks/ambient.jsonl" \
   && grep -q '"pr":"1234"' "$SANDBOX/locks/ambient.jsonl"; then
    ok "ambient.jsonl event written with path + gap_id + pr"
else
    fail "ambient.jsonl event missing or malformed: $(cat "$SANDBOX/locks/ambient.jsonl" 2>/dev/null || echo NONE)"
fi

# Now flip to a non-hot edit. New branch off main, edit a non-hot path.
cd "$SANDBOX"
git checkout -q main
git checkout -q -b cool-feature
mkdir -p src
echo "fn main(){}" > src/lib.rs
git add src/lib.rs
git commit -q -m "code"

rm -f "$SANDBOX/locks/ambient.jsonl"
COLD_OUT="$SANDBOX/cold.stderr"
SANDBOX="$SANDBOX" bash "$HARNESS" "9999" "OTHER-1" 2>"$COLD_OUT" >/dev/null

if [[ ! -s "$COLD_OUT" ]] || ! grep -q "HOT FILE" "$COLD_OUT"; then
    ok "no HOT FILE stderr note for non-hot diff"
else
    fail "spurious HOT FILE note for non-hot diff: $(cat "$COLD_OUT")"
fi

if [[ ! -s "$SANDBOX/locks/ambient.jsonl" ]]; then
    ok "no ambient event written for non-hot diff"
else
    fail "spurious ambient event written for non-hot diff: $(cat "$SANDBOX/locks/ambient.jsonl")"
fi

cd "$REPO_ROOT"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    echo
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
