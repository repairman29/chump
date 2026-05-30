#!/usr/bin/env bash
# nextest-flake-check.sh — META-141 cargo-nextest integration helper.
#
# Source this after running cargo nextest to check whether a failed test
# should be treated as quarantined rather than a hard failure.
#
# Usage in CI (example):
#   source scripts/coord/lib/flake-quarantine.sh
#   source scripts/coord/lib/nextest-flake-check.sh
#
#   # Run nextest, capture exit code
#   cargo nextest run ... 2>&1 | tee /tmp/nextest.out; nextest_rc=${PIPESTATUS[0]}
#
#   check_nextest_failures /tmp/nextest.out $nextest_rc
#   exit $?   # 0 if all failures were quarantined, nextest_rc otherwise
#
# The helper reads nextest output for lines matching:
#   FAILED [time] <crate>::<test_path>
# then computes the fingerprint from the failure message, checks quarantine,
# and either emits a flake_skipped event (quarantined) or passes through
# the original non-zero exit code (real failure).

# Requires flake-quarantine.sh to be sourced first.
if ! declare -f is_flake_quarantined >/dev/null 2>&1; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=./flake-quarantine.sh
    source "$SCRIPT_DIR/flake-quarantine.sh"
fi

# check_nextest_failures <nextest_output_file> <nextest_exit_code>
# Returns 0 if all failures were quarantined (treat as SUCCESS-WITH-QUARANTINE),
# returns the original exit code if any unquarantined failure remains.
check_nextest_failures() {
    local output_file="$1"
    local original_rc="${2:-0}"

    # No failure → pass through
    if [[ "$original_rc" == "0" ]]; then
        return 0
    fi

    if [[ "${CHUMP_FLAKE_QUARANTINE:-1}" == "0" ]]; then
        return "$original_rc"
    fi

    if [[ ! -f "$output_file" ]]; then
        echo "[nextest-flake-check] output file not found: $output_file" >&2
        return "$original_rc"
    fi

    local all_quarantined=1
    local skipped_count=0
    local real_fail_count=0

    # Parse each FAILED line from nextest output
    # Format: "FAILED [  0.123s]  crate::module::test_name"
    while IFS= read -r line; do
        # Extract test path
        local test_path
        test_path="$(printf '%s' "$line" | sed -E 's/.*FAILED[[:space:]]+\[[^]]+\][[:space:]]+(.*)/\1/' | xargs)"
        [[ -z "$test_path" ]] && continue

        # Extract error context: find next STDERR lines after this FAILED marker
        # For fingerprint we use the test name itself as a stable proxy when no
        # detailed stderr is captured in the output file.
        local error_text="$test_path"
        local fingerprint
        fingerprint="$(printf '%s' "${error_text:0:200}" | sha256sum | cut -c1-16)"

        if is_flake_quarantined "$fingerprint" || is_test_path_quarantined "$test_path"; then
            record_flake_skip "$fingerprint" "$test_path"
            skipped_count=$((skipped_count + 1))
        else
            echo "[nextest-flake-check] REAL FAILURE (not quarantined): $test_path" >&2
            real_fail_count=$((real_fail_count + 1))
            all_quarantined=0
        fi
    done < <(grep -E 'FAILED[[:space:]]+\[' "$output_file" 2>/dev/null || true)

    if [[ "$all_quarantined" == "1" ]] && [[ "$skipped_count" -gt 0 ]]; then
        echo "[nextest-flake-check] SUCCESS-WITH-QUARANTINE: $skipped_count quarantined test(s) skipped"
        return 0
    fi

    if [[ "$skipped_count" -gt 0 ]]; then
        echo "[nextest-flake-check] $skipped_count quarantined skip(s), $real_fail_count real failure(s)"
    fi

    return "$original_rc"
}
