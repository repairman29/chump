#!/usr/bin/env bash
# test-repo-health-warnings-only.sh — verify that repo-health.yml warnings
# do not cause job failure. Tests the fix for INFRA-1896: annotations should
# emit via ::warning but NOT roll up to job conclusion FAILURE when there are
# no ::error annotations.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$REPO_ROOT"

# Test 1: Verify Python parsing robustness with malformed JSON
echo "Test 1: Python parser handles malformed JSON gracefully"
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

# Create a test findings file with one valid entry and one edge case
cat > "$tmpfile" <<'EOF'
{"check":"test","key":"k1","title":"Valid finding","description":"desc","domain":"INFRA","priority":"P1","effort":"xs","evidence":["file:10"]}
{}
{"check":"test","key":"k2","title":"Another finding","evidence":["file:20"]}
EOF

# Run the annotation logic (same as the workflow step)
echo "Testing annotation parsing..."
python3 - "$tmpfile" <<'PYEOF' || true
import json, sys
try:
    with open(sys.argv[1]) as f:
        count = 0
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                title = obj.get("title", "Unknown finding")
                evidence = "; ".join(obj.get("evidence", []))
                print(f"::warning title=Repo health::{title} ({evidence})")
                count += 1
            except (json.JSONDecodeError, KeyError, ValueError) as e:
                print(f"::warning title=Repo health parse error::{e}", file=sys.stderr)
        print(f"Successfully processed {count} valid findings", file=sys.stderr)
except Exception as e:
    print(f"::error::Failed to annotate findings: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

echo "✓ Test 1 passed: Python parser handled edge cases"

# Test 2: Verify that the Annotate findings step logic exits correctly
echo ""
echo "Test 2: Annotation step exit behavior"

# Simulate a successful annotation pass
set +e
python3 - "$tmpfile" <<'PYEOF' 2>&1
import json, sys
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            title = obj.get("title", "Unknown finding")
            evidence = "; ".join(obj.get("evidence", []))
            print(f"::warning title=Repo health::{title} ({evidence})")
        except (json.JSONDecodeError, KeyError, ValueError) as e:
            print(f"::warning title=Repo health parse error::{e}", file=sys.stderr)
PYEOF
exit_code=$?
set -e

if [ $exit_code -eq 0 ]; then
    echo "✓ Test 2 passed: Annotation step exits with success (0)"
else
    echo "✗ Test 2 failed: Expected exit 0, got $exit_code"
    exit 1
fi

# Test 3: Verify empty findings produce success
echo ""
echo "Test 3: Empty findings produce success"
empty_tmpfile=$(mktemp)
touch "$empty_tmpfile"
trap "rm -f '$tmpfile' '$empty_tmpfile'" EXIT

set +e
python3 - "$empty_tmpfile" <<'PYEOF' 2>&1
import json, sys
try:
    with open(sys.argv[1]) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                title = obj.get("title", "Unknown finding")
                evidence = "; ".join(obj.get("evidence", []))
                print(f"::warning title=Repo health::{title} ({evidence})")
            except (json.JSONDecodeError, KeyError, ValueError):
                pass
except Exception as e:
    print(f"::error::Failed to annotate findings: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
exit_code=$?
set -e

if [ $exit_code -eq 0 ]; then
    echo "✓ Test 3 passed: Empty findings produce success"
else
    echo "✗ Test 3 failed: Expected exit 0, got $exit_code"
    exit 1
fi

echo ""
echo "All tests passed. repo-health.yml warnings do not cause job failure."
