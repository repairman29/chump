#!/usr/bin/env bash
# test-yaml-lint-guard.sh — regression test for the INFRA-073 YAML-validity
# guard in scripts/git-hooks/pre-commit.
#
# Concrete incident: commit 26e74937 (INFRA-070) wrote
#   - regression test: hand-add a gap to YAML, do not import, then reserve;
# as an unquoted list item. The embedded colon turned the list item into a
# malformed mapping; PyYAML refused to parse the file. cli_smoke tests
# crashed with "could not find expected ':' at line 11083" in CI for every
# PR until PR #542 drive-by quoted the line.
#
# Acceptance:
#   (1) hook rejects a commit that leaves docs/gaps.yaml unparseable
#   (2) hook allows a commit that keeps the file parseable
#   (3) CHUMP_GAPS_LOCK=0 bypasses the check
#
# Run:
#   ./scripts/test-yaml-lint-guard.sh
#
# Exits non-zero on any failure.

set -euo pipefail

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/git-hooks/pre-commit"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ ! -x "$HOOK" ]]; then
    echo "  FAIL: pre-commit hook not executable at $HOOK"
    exit 1
fi

if ! python3 -c "import yaml" 2>/dev/null; then
    echo "  SKIP: PyYAML not installed in test env — guard is a silent no-op there"
    exit 0
fi

echo "=== INFRA-073 YAML-lint guard regression tests ==="
echo

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Set up an isolated git repo with the hook installed.
cd "$TMP"
git init -q .
git config user.email "test@test"
git config user.name "test"
mkdir -p docs scripts/git-hooks
cp "$HOOK" .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit

# Seed with a known-good gaps.yaml.
cat > docs/gaps.yaml <<'EOF'
meta:
  version: '1'
gaps:
  - id: TEST-001
    title: seed entry
    status: open
EOF
git add docs/gaps.yaml
# CHUMP_GAPS_LOCK=0 to skip *all* gaps.yaml guards on the seed commit
# (the seed YAML is fine; we want to bypass the unrelated discipline checks
# that complain about adding new IDs the first time).
CHUMP_GAPS_LOCK=0 git commit -q -m "seed"

# (1) Stage a gaps.yaml with broken YAML — guard must reject.
cat > docs/gaps.yaml <<'EOF'
meta:
  version: '1'
gaps:
  - id: TEST-001
    title: seed entry
    status: open
    acceptance_criteria:
      - regression test: hand-add a gap; do not import; then reserve
        and assert returned ID is strictly greater than the YAML max
EOF
git add docs/gaps.yaml
if git commit -q -m "broken yaml" 2>/dev/null; then
    fail "guard accepted a commit that leaves gaps.yaml unparseable"
    git reset --soft HEAD~1 >/dev/null
else
    rc=$?
    if [[ $rc -eq 1 ]]; then
        ok "guard rejected unparseable YAML (exit 1)"
    else
        fail "guard rejected with exit $rc (expected 1)"
    fi
fi

# (2) CHUMP_GAPS_LOCK=0 bypass on the same broken state.
if CHUMP_GAPS_LOCK=0 git commit -q -m "bypass test" 2>/dev/null; then
    ok "CHUMP_GAPS_LOCK=0 bypasses the YAML-lint guard"
    git reset --hard HEAD~1 >/dev/null 2>&1
else
    fail "CHUMP_GAPS_LOCK=0 did not bypass the guard"
fi

# (3) Stage a gaps.yaml that's valid — guard must allow.
cat > docs/gaps.yaml <<'EOF'
meta:
  version: '1'
gaps:
  - id: TEST-001
    title: seed entry
    status: open
  - id: TEST-002
    title: new entry
    status: open
    acceptance_criteria:
      - 'regression test: hand-add a gap; do not import; then reserve'
EOF
git add docs/gaps.yaml
if git commit -q -m "valid yaml" 2>/dev/null; then
    ok "guard accepted parseable YAML"
else
    fail "guard rejected valid YAML"
fi

echo
echo "=== Result ==="
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
