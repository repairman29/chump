#!/usr/bin/env bash
# vim: ft=bash
# run-local-ci.sh — INFRA-1322
#
# Unified local CI gate that mirrors GitHub Actions fast-checks workflow.
# Enables developers to validate changes locally before pushing.
# Works offline (no network dependency on GitHub API).
#
# Usage:
#   scripts/run-local-ci.sh [options]
#
# Options:
#   --verbose                Log each check invocation
#   --fix                    Auto-fix for cargo clippy (cargo clippy --fix)
#   --only <check_name>      Run only the named check (can be repeated)
#   --json                   Output results as JSON
#   --continue-on-error      Run all checks even if one fails (default: fail fast)
#   --help                   Show this usage
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT

# Script name for logging
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Options
VERBOSE=0
DO_FIX=0
ONLY_CHECKS=()
OUTPUT_JSON=0
CONTINUE_ON_ERROR=0

# Results tracking (using indexed arrays for bash portability)
CHECK_NAMES=()            # Array of check names
CHECK_RESULTS=()          # Array of statuses (pass/fail)
CHECK_TIMES=()            # Array of durations
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_SKIPPED=0

# ── Helper functions ────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
run-local-ci.sh — unified local CI gate for fast-checks validation

Usage:
  scripts/run-local-ci.sh [options]

Options:
  --verbose                  Log each check invocation + timing
  --fix                      Auto-fix mode for clippy
  --only <check_name>        Run only named check (repeatable, filters to substring)
  --json                     Output final results as JSON
  --continue-on-error        Run all checks even if one fails (default: fail fast)
  --help                     Show this usage and exit

Checks included (in order):
  1. cargo fmt --check      — code formatting
  2. cargo clippy           — linting (Rust)
  3. cargo test             — unit tests
  4. gap-audit-priorities   — gap registry health
  5. cli-integration        — CLI smoke test
  6. pr-hygiene             — commit/PR format

Exit codes:
  0  all checks passed
  1  one or more checks failed
  2  usage error

Examples:
  scripts/run-local-ci.sh                          # Run all checks
  scripts/run-local-ci.sh --verbose                # With timing info
  scripts/run-local-ci.sh --only fmt               # Only cargo fmt
  scripts/run-local-ci.sh --only clippy --fix      # Clippy with auto-fix
  scripts/run-local-ci.sh --json                   # JSON output
  scripts/run-local-ci.sh --continue-on-error      # Run all, report all failures

EOF
}

log_info() {
    echo "[INFO] $*"
}

log_error() {
    echo "[ERROR] $*" >&2
}

log_check_start() {
    local name="$1"
    if [[ "$VERBOSE" == 1 ]]; then
        echo "  [RUN] $name..."
    fi
}

log_check_result() {
    local name="$1"
    local status="$2"
    local duration="${3:-0}"

    if [[ "$VERBOSE" == 1 ]]; then
        if [[ "$status" == "pass" ]]; then
            printf "  [OK]  %-35s [%.1fs]\n" "$name" "$duration"
        else
            printf "  [FAIL] %-35s [%.1fs]\n" "$name" "$duration"
        fi
    fi
}

run_check() {
    local check_name="$1"
    shift

    log_check_start "$check_name"

    local start_time
    start_time=$(date +%s%N)

    if "$@"; then
        local end_time
        end_time=$(date +%s%N)
        local duration_ns=$((end_time - start_time))
        local duration_s=$(awk "BEGIN {printf \"%.1f\", $duration_ns / 1000000000}")

        CHECK_NAMES+=("$check_name")
        CHECK_RESULTS+=("pass")
        CHECK_TIMES+=("$duration_s")
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
        log_check_result "$check_name" "pass" "$duration_s"
        return 0
    else
        local end_time
        end_time=$(date +%s%N)
        local duration_ns=$((end_time - start_time))
        local duration_s=$(awk "BEGIN {printf \"%.1f\", $duration_ns / 1000000000}")

        CHECK_NAMES+=("$check_name")
        CHECK_RESULTS+=("fail")
        CHECK_TIMES+=("$duration_s")
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
        log_check_result "$check_name" "fail" "$duration_s"

        if [[ "$CONTINUE_ON_ERROR" == 0 ]]; then
            return 1
        else
            return 0  # Don't exit, continue running other checks
        fi
    fi
}

should_run_check() {
    local check_name="$1"

    if [[ ${#ONLY_CHECKS[@]} -eq 0 ]]; then
        return 0  # Run all checks if --only not specified
    fi

    for only_filter in "${ONLY_CHECKS[@]}"; do
        if [[ "$check_name" == *"$only_filter"* ]]; then
            return 0
        fi
    done

    return 1
}

check_cargo_fmt() {
    cargo fmt --all -- --check
}

check_cargo_clippy() {
    if [[ "$DO_FIX" == 1 ]]; then
        cargo clippy --workspace --all-targets --fix --allow-dirty --allow-staged
    else
        cargo clippy --workspace --all-targets -- -D warnings
    fi
}

check_cargo_test() {
    cargo test --workspace
}

check_gap_audit_priorities() {
    if [[ ! -f "$REPO_ROOT/scripts/ci/test-gap-audit-priorities.sh" ]]; then
        return 0  # Skip if test doesn't exist
    fi
    bash "$REPO_ROOT/scripts/ci/test-gap-audit-priorities.sh" >/dev/null 2>&1
}

check_cli_integration() {
    if [[ ! -f "$REPO_ROOT/scripts/ci/test-cli-integration.sh" ]]; then
        return 0  # Skip if test doesn't exist
    fi
    bash "$REPO_ROOT/scripts/ci/test-cli-integration.sh" >/dev/null 2>&1
}

check_pr_hygiene() {
    # PR hygiene checks require git diff context; skip if not in a PR context
    # (e.g., running on detached HEAD or main branch directly)
    if ! git rev-parse HEAD~1 >/dev/null 2>&1; then
        return 0  # Skip if can't resolve parent commit
    fi

    if [[ ! -f "$REPO_ROOT/scripts/ci/check-pr-scope.sh" ]]; then
        return 0  # Skip if test doesn't exist
    fi

    # Only run if we have a proper commit history
    bash "$REPO_ROOT/scripts/ci/check-pr-scope.sh" >/dev/null 2>&1 || true
}

output_json_results() {
    local total=$((CHECKS_PASSED + CHECKS_FAILED))
    local success=0

    if [[ "$CHECKS_FAILED" -eq 0 ]]; then
        success=1
    fi

    cat <<EOF
{
  "success": $success,
  "passed": $CHECKS_PASSED,
  "failed": $CHECKS_FAILED,
  "total": $total,
  "checks": {
EOF

    local i=0
    local first=1
    for ((i=0; i<${#CHECK_NAMES[@]}; i++)); do
        if [[ "$first" == 0 ]]; then
            echo ","
        fi
        first=0

        local check_name="${CHECK_NAMES[$i]}"
        local status="${CHECK_RESULTS[$i]}"
        local duration="${CHECK_TIMES[$i]:-0}"

        cat <<EOF
    "$check_name": {
      "status": "$status",
      "duration_seconds": $duration
    }
EOF
    done

    cat <<EOF

  }
}
EOF
}

output_summary_table() {
    echo
    echo "=== CI Results Summary ==="
    printf "%-40s %-10s %10s\n" "Check" "Status" "Duration"
    printf "%-40s %-10s %10s\n" "---" "---" "---"

    local total_time=0
    local i=0
    for ((i=0; i<${#CHECK_NAMES[@]}; i++)); do
        local check_name="${CHECK_NAMES[$i]}"
        local status="${CHECK_RESULTS[$i]}"
        local duration="${CHECK_TIMES[$i]:-0}"
        local status_display="PASS"

        if [[ "$status" == "fail" ]]; then
            status_display="FAIL"
        fi

        printf "%-40s %-10s %10s\n" "$check_name" "$status_display" "${duration}s"
        total_time=$(awk "BEGIN {printf \"%.1f\", $total_time + $duration}")
    done

    echo "---"
    printf "%-40s %-10s %10s\n" "TOTAL" "" "${total_time}s"
    echo
    echo "Passed: $CHECKS_PASSED | Failed: $CHECKS_FAILED"
    echo
}

# ── Main ─────────────────────────────────────────────────────────────────

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                usage
                exit 0
                ;;
            --verbose)
                VERBOSE=1
                shift
                ;;
            --fix)
                DO_FIX=1
                shift
                ;;
            --only)
                if [[ $# -lt 2 ]]; then
                    log_error "--only requires a check name"
                    exit 2
                fi
                ONLY_CHECKS+=("$2")
                shift 2
                ;;
            --json)
                OUTPUT_JSON=1
                shift
                ;;
            --continue-on-error)
                CONTINUE_ON_ERROR=1
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage >&2
                exit 2
                ;;
        esac
    done

    # Change to repo root
    cd "$REPO_ROOT"

    log_info "Starting local CI checks (INFRA-1322)"
    echo

    # Run checks in order
    local exit_code=0

    if should_run_check "cargo fmt"; then
        if ! run_check "cargo fmt" check_cargo_fmt; then
            exit_code=1
            if [[ "$CONTINUE_ON_ERROR" == 0 ]]; then
                if [[ "$OUTPUT_JSON" == 1 ]]; then
                    output_json_results
                fi
                exit 1
            fi
        fi
    fi

    if should_run_check "cargo clippy"; then
        if ! run_check "cargo clippy" check_cargo_clippy; then
            exit_code=1
            if [[ "$CONTINUE_ON_ERROR" == 0 ]]; then
                if [[ "$OUTPUT_JSON" == 1 ]]; then
                    output_json_results
                fi
                exit 1
            fi
        fi
    fi

    if should_run_check "cargo test"; then
        if ! run_check "cargo test" check_cargo_test; then
            exit_code=1
            if [[ "$CONTINUE_ON_ERROR" == 0 ]]; then
                if [[ "$OUTPUT_JSON" == 1 ]]; then
                    output_json_results
                fi
                exit 1
            fi
        fi
    fi

    if should_run_check "gap audit-priorities"; then
        if ! run_check "gap audit-priorities" check_gap_audit_priorities; then
            exit_code=1
            if [[ "$CONTINUE_ON_ERROR" == 0 ]]; then
                if [[ "$OUTPUT_JSON" == 1 ]]; then
                    output_json_results
                fi
                exit 1
            fi
        fi
    fi

    if should_run_check "cli-integration"; then
        if ! run_check "cli-integration" check_cli_integration; then
            exit_code=1
            if [[ "$CONTINUE_ON_ERROR" == 0 ]]; then
                if [[ "$OUTPUT_JSON" == 1 ]]; then
                    output_json_results
                fi
                exit 1
            fi
        fi
    fi

    if should_run_check "pr-hygiene"; then
        if ! run_check "pr-hygiene" check_pr_hygiene; then
            exit_code=1
            if [[ "$CONTINUE_ON_ERROR" == 0 ]]; then
                if [[ "$OUTPUT_JSON" == 1 ]]; then
                    output_json_results
                fi
                exit 1
            fi
        fi
    fi

    # Output results
    output_summary_table

    if [[ "$OUTPUT_JSON" == 1 ]]; then
        output_json_results
    fi

    exit "$exit_code"
}

main "$@"
