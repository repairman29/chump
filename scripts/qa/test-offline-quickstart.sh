#!/usr/bin/env bash
# Smoke-test fixture for docs/QUICKSTART_OFFLINE.md.
# Validates the doc exists, is well-formed, and that Ollama + chump are reachable
# when invoked in a real environment.  Skips live network checks in CI where
# CHUMP_OFFLINE_QA_SKIP_LIVE is set.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOC="$REPO_ROOT/docs/QUICKSTART_OFFLINE.md"

pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*" >&2; exit 1; }
skip() { echo "  [SKIP] $*"; }

echo "=== test-offline-quickstart.sh ==="

# 1. Doc exists
[[ -f "$DOC" ]] || fail "docs/QUICKSTART_OFFLINE.md not found"
pass "doc exists"

# 2. All 5 steps present
for step in 1 2 3 4 5; do
  grep -q "## Step $step" "$DOC" || fail "Step $step missing from $DOC"
done
pass "all 5 steps present"

# 3. Required commands mentioned
for cmd in "brew tap repairman29/chump" "ollama pull llama3.2" \
           "OPENAI_API_BASE" "chump --once" "chump gap reserve" "chump claim" "chump dispatch"; do
  grep -q "$cmd" "$DOC" || fail "Expected command/phrase not found: $cmd"
done
pass "required commands referenced"

# 4. README links back to the doc
README="$REPO_ROOT/README.md"
grep -q "QUICKSTART_OFFLINE" "$README" || fail "README.md does not link to QUICKSTART_OFFLINE.md"
pass "README links to doc"

# 5. Live checks (skip in CI)
if [[ "${CHUMP_OFFLINE_QA_SKIP_LIVE:-}" == "1" ]]; then
  skip "live checks skipped (CHUMP_OFFLINE_QA_SKIP_LIVE=1)"
else
  # 5a. Ollama reachable
  if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
    pass "Ollama reachable on :11434"
  else
    skip "Ollama not running — start with 'ollama serve' to run live checks"
  fi

  # 5b. chump binary present
  if command -v chump >/dev/null 2>&1; then
    pass "chump binary found: $(command -v chump)"
  else
    skip "chump not installed — install with 'brew tap repairman29/chump && brew install chump'"
  fi
fi

echo "=== all checks passed ==="
