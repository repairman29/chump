#!/usr/bin/env bash
set -eu

# EVAL-103: Test suite for prereg-enforce.sh
# Verifies that the runtime enforcement gates catch all configured violations
# and pass when all fields match.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the enforcement library
source "$SCRIPT_DIR/eval/lib/prereg-enforce.sh"

# Test fixtures
TEST_TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEST_TEMP_DIR" EXIT

# Create a minimal test preregistration document
create_test_prereg() {
    local fixture_path="$1"
    local model="$2"
    local n_per_cell="$3"
    local judges="${4:-claude-haiku-4-5,meta-llama/Llama-3.3-70B-Instruct}"

    cat > "$fixture_path" << 'EOF'
# Preregistration — `EVAL-102-TEST` (test fixture)

## 12. Locked-fields manifest

```yaml
# Test manifest for enforcement testing
prereg_locked:
  gap_id: EVAL-102-TEST
  primary_agent: claude-sonnet-4-6
  n_per_cell: 50
  fixture: scripts/ab-harness/fixtures/reflection_tasks.json
  judge_models:
    - claude-haiku-4-5
    - meta-llama/Llama-3.3-70B-Instruct
```

## 13. Deviations (append-only, timestamped)

*(none yet)*
EOF

    # Replace values if provided
    sed -i.bak "s/claude-sonnet-4-6/$model/" "$fixture_path"
    sed -i.bak "s/n_per_cell: 50/n_per_cell: $n_per_cell/" "$fixture_path"
    rm -f "$fixture_path.bak"
}

# Test 1: Pass with all correct fields
test_pass_all_correct() {
    local test_name="test_pass_all_correct"
    local prereg_path="$TEST_TEMP_DIR/eval-102-test.md"

    create_test_prereg "$prereg_path" "claude-sonnet-4-6" "50"

    if enforce_prereg_manifest "$prereg_path" \
        --model claude-sonnet-4-6 \
        --n-per-cell 50 \
        --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
        --judges "claude-haiku-4-5,meta-llama/Llama-3.3-70B-Instruct"; then
        echo "✓ $test_name PASSED"
        return 0
    else
        echo "✗ $test_name FAILED: expected pass but got fail"
        return 1
    fi
}

# Test 2: Fail on model mismatch
test_fail_model_mismatch() {
    local test_name="test_fail_model_mismatch"
    local prereg_path="$TEST_TEMP_DIR/eval-102-model-mismatch.md"

    create_test_prereg "$prereg_path" "claude-sonnet-4-6" "50"

    if enforce_prereg_manifest "$prereg_path" \
        --model claude-opus-4-7 \
        --n-per-cell 50 \
        --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
        --judges "claude-haiku-4-5,meta-llama/Llama-3.3-70B-Instruct" 2>/dev/null; then
        echo "✗ $test_name FAILED: expected fail on model mismatch"
        return 1
    else
        if [[ " ${MISMATCHED_FIELDS[@]} " =~ "primary_agent" ]]; then
            echo "✓ $test_name PASSED"
            return 0
        else
            echo "✗ $test_name FAILED: mismatch detected but primary_agent not in MISMATCHED_FIELDS"
            return 1
        fi
    fi
}

# Test 3: Fail on n_per_cell too small
test_fail_n_too_small() {
    local test_name="test_fail_n_too_small"
    local prereg_path="$TEST_TEMP_DIR/eval-102-n-small.md"

    create_test_prereg "$prereg_path" "claude-sonnet-4-6" "50"

    if enforce_prereg_manifest "$prereg_path" \
        --model claude-sonnet-4-6 \
        --n-per-cell 20 \
        --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
        --judges "claude-haiku-4-5,meta-llama/Llama-3.3-70B-Instruct" 2>/dev/null; then
        echo "✗ $test_name FAILED: expected fail on n_per_cell < manifest"
        return 1
    else
        if [[ " ${MISMATCHED_FIELDS[@]} " =~ "n_per_cell" ]]; then
            echo "✓ $test_name PASSED"
            return 0
        else
            echo "✗ $test_name FAILED: mismatch detected but n_per_cell not in MISMATCHED_FIELDS"
            return 1
        fi
    fi
}

# Test 4: Pass with n_per_cell >= manifest
test_pass_n_larger() {
    local test_name="test_pass_n_larger"
    local prereg_path="$TEST_TEMP_DIR/eval-102-n-larger.md"

    create_test_prereg "$prereg_path" "claude-sonnet-4-6" "50"

    if enforce_prereg_manifest "$prereg_path" \
        --model claude-sonnet-4-6 \
        --n-per-cell 100 \
        --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
        --judges "claude-haiku-4-5,meta-llama/Llama-3.3-70B-Instruct"; then
        echo "✓ $test_name PASSED"
        return 0
    else
        echo "✗ $test_name FAILED: expected pass with n_per_cell > manifest"
        return 1
    fi
}

# Test 5: Fail on fixture mismatch
test_fail_fixture_mismatch() {
    local test_name="test_fail_fixture_mismatch"
    local prereg_path="$TEST_TEMP_DIR/eval-102-fixture-mismatch.md"

    create_test_prereg "$prereg_path" "claude-sonnet-4-6" "50"

    if enforce_prereg_manifest "$prereg_path" \
        --model claude-sonnet-4-6 \
        --n-per-cell 50 \
        --fixture scripts/ab-harness/fixtures/wrong_fixture.json \
        --judges "claude-haiku-4-5,meta-llama/Llama-3.3-70B-Instruct" 2>/dev/null; then
        echo "✗ $test_name FAILED: expected fail on fixture mismatch"
        return 1
    else
        if [[ " ${MISMATCHED_FIELDS[@]} " =~ "fixture" ]]; then
            echo "✓ $test_name PASSED"
            return 0
        else
            echo "✗ $test_name FAILED: mismatch detected but fixture not in MISMATCHED_FIELDS"
            return 1
        fi
    fi
}

# Test 6: Fail on judge models mismatch
test_fail_judges_mismatch() {
    local test_name="test_fail_judges_mismatch"
    local prereg_path="$TEST_TEMP_DIR/eval-102-judges-mismatch.md"

    create_test_prereg "$prereg_path" "claude-sonnet-4-6" "50"

    if enforce_prereg_manifest "$prereg_path" \
        --model claude-sonnet-4-6 \
        --n-per-cell 50 \
        --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
        --judges "claude-opus-4-7,gpt-4" 2>/dev/null; then
        echo "✗ $test_name FAILED: expected fail on judges mismatch"
        return 1
    else
        if [[ " ${MISMATCHED_FIELDS[@]} " =~ "judge_models" ]]; then
            echo "✓ $test_name PASSED"
            return 0
        else
            echo "✗ $test_name FAILED: mismatch detected but judge_models not in MISMATCHED_FIELDS"
            return 1
        fi
    fi
}

# Test 7: Fail on scorer prohibition (CHUMP_AB_SCORER=exit-code)
test_fail_scorer_prohibition() {
    local test_name="test_fail_scorer_prohibition"
    local prereg_path="$TEST_TEMP_DIR/eval-102-scorer.md"

    create_test_prereg "$prereg_path" "claude-sonnet-4-6" "50"

    export CHUMP_AB_SCORER="exit-code"
    if enforce_prereg_manifest "$prereg_path" \
        --model claude-sonnet-4-6 \
        --n-per-cell 50 \
        --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
        --judges "claude-haiku-4-5,meta-llama/Llama-3.3-70B-Instruct" 2>/dev/null; then
        echo "✗ $test_name FAILED: expected fail on scorer=exit-code"
        unset CHUMP_AB_SCORER
        return 1
    else
        if [[ " ${MISMATCHED_FIELDS[@]} " =~ "scorer_prohibition" ]]; then
            echo "✓ $test_name PASSED"
            unset CHUMP_AB_SCORER
            return 0
        else
            echo "✗ $test_name FAILED: scorer violation detected but not in MISMATCHED_FIELDS"
            unset CHUMP_AB_SCORER
            return 1
        fi
    fi
}

# Test 8: Fail when file doesn't exist
test_fail_file_missing() {
    local test_name="test_fail_file_missing"
    local prereg_path="$TEST_TEMP_DIR/nonexistent.md"

    if enforce_prereg_manifest "$prereg_path" \
        --model claude-sonnet-4-6 \
        --n-per-cell 50 2>/dev/null; then
        echo "✗ $test_name FAILED: expected fail on missing file"
        return 1
    else
        echo "✓ $test_name PASSED"
        return 0
    fi
}

# Run all tests
main() {
    echo "Running EVAL-103 prereg-enforce.sh tests..."
    echo

    local failed=0
    test_pass_all_correct || ((failed++))
    test_fail_model_mismatch || ((failed++))
    test_fail_n_too_small || ((failed++))
    test_pass_n_larger || ((failed++))
    test_fail_fixture_mismatch || ((failed++))
    test_fail_judges_mismatch || ((failed++))
    test_fail_scorer_prohibition || ((failed++))
    test_fail_file_missing || ((failed++))

    echo
    if [[ $failed -eq 0 ]]; then
        echo "All tests passed!"
        return 0
    else
        echo "$failed test(s) failed"
        return 1
    fi
}

main "$@"
