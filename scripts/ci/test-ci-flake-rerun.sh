#!/usr/bin/env bash
# test-ci-flake-rerun.sh — INFRA-375 smoke test.
#
# Exercises scripts/ops/ci-flake-rerun.sh with stubbed `gh` on PATH.
# Verifies:
#   1. CHUMP_CI_FLAKE_RERUN=0 bypasses cleanly (exit 0, "bypass" in output).
#   2. Empty PR list short-circuits without error.
#   3. --dry-run output shows "would rerun" when a flake pattern matches.
#   4. Non-matching failure is left alone (no "would rerun").
#   5. Per-run-id cooldown prevents a second rerun attempt.
#
# Network-free: stubs `gh` via PATH.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/ci-flake-rerun.sh"

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
export PATH="$TMP/bin:$PATH"

# Reaper instrumentation resolves REAPER_REPO_ROOT from git. Stand up a
# minimal bare+working-tree pair so git commands succeed.
git init -q --bare "$TMP/origin.git" >/dev/null
git init -q -b main "$TMP/repo" >/dev/null
cd "$TMP/repo"
git config user.email "test@chump.local"
git config user.name "Chump Test"
echo init > README.md
git add README.md && git commit -qm "init"
git remote add origin "$TMP/origin.git"
git push -q origin main

# reaper_setup sets REAPER_REPO_ROOT = git common-dir parent = $TMP/repo.
# The script builds COOLDOWN_DIR off that, so create the dir here too.
COOLDOWN_DIR="$TMP/repo/.chump-locks/ci-flake-cooldown"
mkdir -p "$COOLDOWN_DIR"
# Point REAPER_LOCK_DIR at our tmp dir to avoid polluting the real ambient.
export REAPER_LOCK_DIR="$TMP/repo/.chump-locks"

# ── Test 1: bypass env exits 0 ───────────────────────────────────────────────
echo "Test 1: CHUMP_CI_FLAKE_RERUN=0 bypasses"
out=$(CHUMP_CI_FLAKE_RERUN=0 "$SCRIPT" 2>&1)
if [[ "$out" == *"bypass"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected 'bypass' in output, got: $out"
    exit 1
fi

# ── Test 2: empty PR list short-circuits ─────────────────────────────────────
echo "Test 2: empty PR list short-circuits"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "[]"
EOF
chmod +x "$TMP/bin/gh"

out=$("$SCRIPT" 2>&1 || true)
if [[ "$out" == *"No open PRs"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected 'No open PRs', got: $out"
    exit 1
fi

# ── Test 3: flake-pattern match → dry-run shows "would rerun" ────────────────
echo "Test 3: flake-pattern match → would rerun"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "pr list "*)
        cat <<'JSON'
[{"number":42,"title":"INFRA-100: flaky test","headRefName":"chump/infra-100","statusCheckRollup":[{"conclusion":"FAILURE","targetUrl":"https://github.com/owner/repo/actions/runs/9999001/job/123"}]}]
JSON
        ;;
    "run view 9999001 --log-failed")
        echo "##[error]The operation was canceled."
        ;;
    *) echo "" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

out=$("$SCRIPT" --dry-run 2>&1 || true)
if [[ "$out" == *"would rerun"*"PR #42"*"9999001"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected 'would rerun PR #42 run 9999001', got:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

# ── Test 4: non-matching failure is left alone ───────────────────────────────
echo "Test 4: non-matching failure is left alone"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "pr list "*)
        cat <<'JSON'
[{"number":55,"title":"INFRA-200: real test failure","headRefName":"chump/infra-200","statusCheckRollup":[{"conclusion":"FAILURE","targetUrl":"https://github.com/owner/repo/actions/runs/9999002/job/456"}]}]
JSON
        ;;
    "run view 9999002 --log-failed")
        echo "assertion failed: expected 42, got 0"
        ;;
    *) echo "" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

out=$("$SCRIPT" --dry-run 2>&1 || true)
if [[ "$out" != *"would rerun"* ]] && [[ "$out" == *"no flake-pattern match"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: non-matching failure should be left alone, got:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

# ── Test 5: per-run-id cooldown prevents second rerun ────────────────────────
echo "Test 5: cooldown prevents second rerun"
# Re-use the flake stub from test 3 but pre-create the cooldown file.
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "pr list "*)
        cat <<'JSON'
[{"number":42,"title":"INFRA-100: flaky test","headRefName":"chump/infra-100","statusCheckRollup":[{"conclusion":"FAILURE","targetUrl":"https://github.com/owner/repo/actions/runs/9999001/job/123"}]}]
JSON
        ;;
    "run view 9999001 --log-failed")
        echo "##[error]The operation was canceled."
        ;;
    *) echo "" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

# In dry-run mode no cooldown file is written, so create it manually.
touch "$COOLDOWN_DIR/run-9999001.ts"

out=$("$SCRIPT" --dry-run 2>&1 || true)
if [[ "$out" != *"would rerun"* ]] && [[ "$out" == *"already attempted rerun"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: cooldown should suppress rerun, got:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

echo ""
echo "All ci-flake-rerun tests passed."
