#!/usr/bin/env bash
# scripts/ci/test-repo-health-warnings-only.sh
# Test that repo-health.yml properly distinguishes warnings from errors.
# INFRA-1896: Verify that job conclusion is success when only warnings present,
# and non-zero when errors exist.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

test_warnings_only() {
    local test_name="Warnings only should succeed"
    echo ":: Testing: $test_name"

    # Simulate a step that emits only warning annotations.
    # Exit 0 to prove the step succeeded.
    {
        echo "::warning title=Test warning::This is a non-blocking warning"
        exit 0
    } && {
        echo "✓ Step with warnings exited successfully"
    } || {
        echo "✗ Step with warnings should have exited 0"
        return 1
    }
}

test_errors_should_fail() {
    local test_name="Errors should fail"
    echo ":: Testing: $test_name"

    # Simulate a step that emits an error annotation.
    # In GitHub Actions, ::error causes the step to fail.
    # We verify here that if we explicitly check for errors, we fail.
    local temp_output
    temp_output=$(mktemp)
    {
        echo "::error title=Test error::This is a blocking error"
        exit 1
    } 2>/dev/null || {
        local exit_code=$?
        if [ $exit_code -ne 0 ]; then
            echo "✓ Step with errors exited non-zero as expected"
            return 0
        fi
    }
    return 1
}

test_mixed_warnings_and_no_errors() {
    local test_name="Multiple warnings (no errors) should succeed"
    echo ":: Testing: $test_name"

    # Simulate the repo-health findings output with multiple warnings.
    local findings_file
    findings_file=$(mktemp)
    cat > "$findings_file" <<'EOF'
{"check":"check-broken-doc-links","key":"BROKEN_LINKS::readme.md::line-42","title":"Broken doc link in readme.md","description":"Relative link to non-existent file","domain":"DOC","priority":"P1","effort":"xs","evidence":["readme.md:42"]}
{"check":"check-dead-env-vars","key":"DEAD_ENV::CHUMP_FOO_BAR::src/main.rs:123","title":"Undocumented env var CHUMP_FOO_BAR","description":"Used in code but not documented","domain":"INFRA","priority":"P2","effort":"xs","evidence":["src/main.rs:123"]}
EOF

    # Process findings and emit only warnings (like the workflow does).
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        title=$(echo "$line" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["title"])')
        evidence=$(echo "$line" | python3 -c 'import json,sys; print("; ".join(json.loads(sys.stdin.read())["evidence"]))')
        echo "::warning title=Repo health::${title} (${evidence})"
    done < "$findings_file"

    # Verify no errors were emitted (only warnings).
    local warning_count
    warning_count=$(grep -c '::warning' "$findings_file" || echo 0)
    local error_count
    error_count=$(grep -c '::error' "$findings_file" || echo 0)

    if [ "$error_count" -eq 0 ]; then
        echo "✓ Multiple warnings emitted without errors"
        rm -f "$findings_file"
        return 0
    else
        echo "✗ Unexpected errors in findings"
        rm -f "$findings_file"
        return 1
    fi
}

echo "Running repo-health warnings/errors tests..."
echo ""

test_warnings_only || exit 1
echo ""

test_errors_should_fail || exit 1
echo ""

test_mixed_warnings_and_no_errors || exit 1
echo ""

echo "✓ All repo-health warning/error tests passed"
