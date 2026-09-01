#!/usr/bin/env bash
# test-pre-commit-ci-parity-autofile.sh — RESILIENT-587
#
# Exercises scripts/git-hooks/pre-commit-ci-parity-autofile.sh against a
# synthetic fixture repo:
#   1. A staged ci.yml with a brand-new, unmirrored gate -> the hook must
#      append an allowlist entry and exit 0 (commit allowed).
#   2. Running the hook again on the same state -> no duplicate entry is
#      appended (AC4: entry already exists -> pass without modification).
#   3. A read-only exceptions file -> the hook must abort (exit 1) rather
#      than silently allow the commit (AC3).
#
# Exit: 0 = all assertions pass; 1 = any assertion fails.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit-ci-parity-autofile.sh"
PARITY_SCRIPT="$REPO_ROOT/scripts/ci/test-preflight-ci-parity.sh"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -x "$HOOK" ]; then
    bad "hook missing or not executable: $HOOK"
    exit 1
fi

TMPDIR_TEST="$(mktemp -d -t test-ci-parity-autofile.XXXXXX)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

FIXTURE_REPO="$TMPDIR_TEST/repo"
mkdir -p "$FIXTURE_REPO/.github/workflows"
(
    cd "$FIXTURE_REPO" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
)

SYNTH_GATE_SCRIPT="scripts/ci/test-synth-always-fail-RESILIENT-587.sh"

cat > "$FIXTURE_REPO/.github/workflows/ci.yml" <<EOF
name: ci
on: [push]
jobs:
  fast-checks:
    runs-on: ubuntu-latest
    steps:
      - name: synthetic new gate (RESILIENT-587 smoke)
        run: bash $SYNTH_GATE_SCRIPT
EOF

PREFLIGHT_SRC="$TMPDIR_TEST/preflight.rs"
GATES_INVENTORY="$TMPDIR_TEST/CI_GATES_INVENTORY.md"
EXCEPTIONS_FILE="$TMPDIR_TEST/preflight-ci-parity-exceptions.txt"

cat > "$PREFLIGHT_SRC" <<'EOF'
// fixture preflight.rs — no mirrors yet
EOF

cat > "$GATES_INVENTORY" <<'EOF'
# fixture CI_GATES_INVENTORY.md

## Tier D
EOF

: > "$EXCEPTIONS_FILE"

run_hook() {
    (
        cd "$FIXTURE_REPO" || exit 1
        git add -A
        CHUMP_PARITY_WORKFLOWS_DIR="$FIXTURE_REPO/.github/workflows" \
        CHUMP_PARITY_PREFLIGHT_SRC="$PREFLIGHT_SRC" \
        CHUMP_PARITY_GATES_INVENTORY="$GATES_INVENTORY" \
        CHUMP_PARITY_EXCEPTIONS_FILE="$EXCEPTIONS_FILE" \
        CHUMP_CI_PARITY_AUTOFILE_SCRIPT="$PARITY_SCRIPT" \
        CHUMP_AMBIENT_LOG="$TMPDIR_TEST/ambient.jsonl" \
        "$HOOK"
    )
}

# ── 1. New unmirrored gate -> hook appends + exits 0 ──────────────────────
if run_hook; then
    ok "hook exits 0 (allows commit) for a new unmirrored gate"
else
    bad "hook blocked the commit instead of auto-filing"
fi

if grep -q "$SYNTH_GATE_SCRIPT" "$EXCEPTIONS_FILE" 2>/dev/null; then
    ok "exceptions file got an entry for the new gate"
else
    bad "exceptions file was not updated with the new gate"
fi

LINE_COUNT_1="$(grep -c "$SYNTH_GATE_SCRIPT" "$EXCEPTIONS_FILE" 2>/dev/null || echo 0)"

# ── 2. Re-run: idempotent, no duplicate entry (AC4) ────────────────────────
if run_hook; then
    ok "second run still exits 0"
else
    bad "second run unexpectedly blocked the commit"
fi

LINE_COUNT_2="$(grep -c "$SYNTH_GATE_SCRIPT" "$EXCEPTIONS_FILE" 2>/dev/null || echo 0)"
if [ "$LINE_COUNT_1" = "$LINE_COUNT_2" ] && [ "$LINE_COUNT_1" -ge 1 ]; then
    ok "no duplicate entry appended on re-run (AC4)"
else
    bad "duplicate entry appended on re-run (before=$LINE_COUNT_1 after=$LINE_COUNT_2)"
fi

# ── 3. Cannot write exceptions file -> hook aborts the commit (AC3) ────────
NEW_GATE_SCRIPT="scripts/ci/test-synth-always-fail-RESILIENT-587-take2.sh"
cat > "$FIXTURE_REPO/.github/workflows/ci.yml" <<EOF
name: ci
on: [push]
jobs:
  fast-checks:
    runs-on: ubuntu-latest
    steps:
      - name: synthetic new gate take 2 (RESILIENT-587 smoke)
        run: bash $NEW_GATE_SCRIPT
EOF

READONLY_EXCEPTIONS="$TMPDIR_TEST/readonly-exceptions.txt"
: > "$READONLY_EXCEPTIONS"
chmod 0444 "$READONLY_EXCEPTIONS"
READONLY_DIR_PERM_RESTORE=0
if [ "$(id -u)" = "0" ]; then
    # root bypasses file permission bits — skip this assertion rather than
    # produce a false failure in a root-run CI container.
    echo "  SKIP: read-only exceptions-file assertion (running as root)"
else
    (
        cd "$FIXTURE_REPO" || exit 1
        git add -A
        CHUMP_PARITY_WORKFLOWS_DIR="$FIXTURE_REPO/.github/workflows" \
        CHUMP_PARITY_PREFLIGHT_SRC="$PREFLIGHT_SRC" \
        CHUMP_PARITY_GATES_INVENTORY="$GATES_INVENTORY" \
        CHUMP_PARITY_EXCEPTIONS_FILE="$READONLY_EXCEPTIONS" \
        CHUMP_CI_PARITY_AUTOFILE_SCRIPT="$PARITY_SCRIPT" \
        CHUMP_AMBIENT_LOG="$TMPDIR_TEST/ambient.jsonl" \
        "$HOOK"
    )
    hook_rc=$?
    if [ "$hook_rc" -ne 0 ]; then
        ok "hook aborts the commit when the exceptions file can't be written (AC3)"
    else
        bad "hook allowed the commit despite an unwritable exceptions file"
    fi
fi
chmod 0644 "$READONLY_EXCEPTIONS" 2>/dev/null || true

echo
echo "test-pre-commit-ci-parity-autofile.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
