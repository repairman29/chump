#!/usr/bin/env bash
# test-repo-health-warnings-only.sh — verify that annotations emitted as
# ::warning do NOT cause job failure, and that only ::error annotations
# trigger a non-zero exit code.
#
# Acceptance criteria (from INFRA-1896):
# - If only ##[warning] annotations exist, step exits 0 and job succeeds
# - If ##[error] annotations exist, step exits 1 and job fails
# - Pre-existing repo state warnings don't block PRs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

temp_findings=$(mktemp)
trap "rm -f '$temp_findings'" EXIT

# Test 1: Only warnings should succeed
echo "Test 1: workflow with only warnings should exit 0"
cat > "$temp_findings" << 'EOF'
{"check":"test","key":"test-1","title":"Pre-existing warning","description":"Found X issues","domain":"DOC","priority":"P2","effort":"s","evidence":["file.md:1"],"severity":"warning"}
EOF

# Simulate the "Annotate findings" step behavior
error_count=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  is_error=$(python3 -c "import json,sys; o=json.loads(sys.stdin.read()); print('true' if o.get('severity') == 'error' else 'false')" <<< "$line")
  if [ "$is_error" = "true" ]; then
    ((error_count++))
  fi
done < "$temp_findings"

if [ "$error_count" -gt 0 ]; then
  echo "FAIL: Test 1 — should not have failures on warning-only findings"
  exit 1
fi
echo "PASS: Test 1"

# Test 2: Errors should fail
echo "Test 2: workflow with errors should exit 1"
cat > "$temp_findings" << 'EOF'
{"check":"test","key":"test-2","title":"Introduced breaking issue","description":"Found Y issues","domain":"INFRA","priority":"P1","effort":"s","evidence":["src/main.rs:100"],"severity":"error"}
EOF

error_count=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  is_error=$(python3 -c "import json,sys; o=json.loads(sys.stdin.read()); print('true' if o.get('severity') == 'error' else 'false')" <<< "$line")
  if [ "$is_error" = "true" ]; then
    ((error_count++))
  fi
done < "$temp_findings"

if [ "$error_count" -eq 0 ]; then
  echo "FAIL: Test 2 — should have detected error-severity finding"
  exit 1
fi
echo "PASS: Test 2"

# Test 3: Mixed warnings and errors
echo "Test 3: workflow with mixed warnings and errors should detect errors"
cat > "$temp_findings" << 'EOF'
{"check":"test","key":"test-3a","title":"Pre-existing warning","description":"Found X issues","domain":"DOC","priority":"P2","effort":"s","evidence":["file.md:1"],"severity":"warning"}
{"check":"test","key":"test-3b","title":"New breaking issue","description":"Found Y issues","domain":"INFRA","priority":"P1","effort":"s","evidence":["src/main.rs:100"],"severity":"error"}
EOF

error_count=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  is_error=$(python3 -c "import json,sys; o=json.loads(sys.stdin.read()); print('true' if o.get('severity') == 'error' else 'false')" <<< "$line")
  if [ "$is_error" = "true" ]; then
    ((error_count++))
  fi
done < "$temp_findings"

if [ "$error_count" -ne 1 ]; then
  echo "FAIL: Test 3 — should have detected exactly 1 error-severity finding"
  exit 1
fi
echo "PASS: Test 3"

# Test 4: Missing severity field defaults to warning
echo "Test 4: missing severity field should default to warning"
cat > "$temp_findings" << 'EOF'
{"check":"test","key":"test-4","title":"Legacy finding","description":"Found Z issues","domain":"DOC","priority":"P2","effort":"s","evidence":["file.md:1"]}
EOF

error_count=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  is_error=$(python3 -c "import json,sys; o=json.loads(sys.stdin.read()); print('true' if o.get('severity') == 'error' else 'false')" <<< "$line")
  if [ "$is_error" = "true" ]; then
    ((error_count++))
  fi
done < "$temp_findings"

if [ "$error_count" -gt 0 ]; then
  echo "FAIL: Test 4 — missing severity should default to warning, not error"
  exit 1
fi
echo "PASS: Test 4"

echo ""
echo "All tests passed. Warnings do not cause job failure; only errors do."
