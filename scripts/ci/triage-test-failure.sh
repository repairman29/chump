#!/usr/bin/env bash
# triage-test-failure.sh — CREDIBLE-013
#
# Classifies cargo-test failures as flake/known-bug/real/unknown by
# cross-referencing docs/process/KNOWN_FLAKES.yaml (INFRA-764).
# Emits a human-readable triage line to stdout and, when running inside
# GitHub Actions, emits a ::notice / ::warning annotation so PR authors
# see the classification directly in the Checks summary.
#
# Usage:
#   triage-test-failure.sh [--log <file>]
#
#   Without --log, reads cargo-test output from stdin.
#   With    --log <file>, reads from that file.
#
# Outputs (stdout):
#   triage: <classification> — <detail>
#
# Classifications:
#   flake        All failing tests are in KNOWN_FLAKES.yaml — auto-rerun queued.
#   known-bug    At least one failure is in KNOWN_FLAKES.yaml but not all.
#   real         No failing tests match the catalog — likely a real bug.
#   unknown      No parseable cargo test failures found in output.
#   pass         No failures detected.
#
# Exit codes:
#   0  pass or flake (flakes are auto-retried by cargo-test-with-rerun.sh)
#   1  real or known-bug failure
#   2  usage error
#
# GitHub Actions annotations:
#   Sets GITHUB_STEP_SUMMARY if the env var is set.
#   Emits ::notice:: / ::warning:: / ::error:: based on classification.
#
# Bypass:
#   CHUMP_TRIAGE_ANNOTATE=0  — skip GitHub annotations (still prints to stdout)

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CATALOG="${CATALOG:-$REPO_ROOT/docs/process/KNOWN_FLAKES.yaml}"

# ── Parse args ────────────────────────────────────────────────────────────
LOG_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --log) LOG_FILE="$2"; shift 2 ;;
        --help|-h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[triage] unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ── Read input ────────────────────────────────────────────────────────────
if [[ -n "$LOG_FILE" ]]; then
    [[ -f "$LOG_FILE" ]] || { echo "[triage] --log file not found: $LOG_FILE" >&2; exit 2; }
    INPUT="$(cat "$LOG_FILE")"
else
    INPUT="$(cat)"
fi

# ── Parse failing test names ──────────────────────────────────────────────
# cargo test prints lines like:
#   test module::tests::foo_bar ... FAILED
# We extract the test name (everything between 'test ' and ' ...').
parse_failures() {
    echo "$INPUT" \
        | grep -E '^test .+ \.\.\. FAILED' \
        | sed -E 's/^test ([^ ]+) \.\.\. FAILED$/\1/' \
        | sort -u
}

# ── Load catalog ──────────────────────────────────────────────────────────
read_catalog() {
    [[ -f "$CATALOG" ]] || return 0
    grep -E '^[[:space:]]*-?[[:space:]]*test:[[:space:]]' "$CATALOG" 2>/dev/null \
        | sed -E 's/^[[:space:]]*-?[[:space:]]*test:[[:space:]]+//; s/[[:space:]]*#.*$//; s/^["'"'"']//; s/["'"'"']$//' \
        | sort -u
}

FAILURES="$(parse_failures)"
CATALOG_TESTS="$(read_catalog)"

# ── Classify ──────────────────────────────────────────────────────────────
classify() {
    local failures="$1"
    local catalog="$2"

    if [[ -z "$failures" ]]; then
        # Check for overall test failure without parseable test lines
        if echo "$INPUT" | grep -qE '(FAILED|error\[E[0-9]+\]|^error:)'; then
            echo "unknown"
        else
            echo "pass"
        fi
        return
    fi

    local total=0 in_catalog=0
    while IFS= read -r test; do
        [[ -z "$test" ]] && continue
        total=$(( total + 1 ))
        if echo "$catalog" | grep -qxF "$test"; then
            in_catalog=$(( in_catalog + 1 ))
        fi
    done <<< "$failures"

    if [[ $total -eq 0 ]]; then
        echo "pass"
    elif [[ $in_catalog -eq $total ]]; then
        echo "flake"
    elif [[ $in_catalog -gt 0 ]]; then
        echo "known-bug"
    else
        echo "real"
    fi
}

CLASS="$(classify "$FAILURES" "$CATALOG_TESTS")"

# ── Build detail line ─────────────────────────────────────────────────────
fail_count() { echo "$FAILURES" | grep -c . 2>/dev/null || echo 0; }
catalog_count() { echo "$CATALOG_TESTS" | grep -c . 2>/dev/null || echo 0; }

n_fail="$(fail_count)"
n_cat="$(catalog_count)"

case "$CLASS" in
    pass)
        MSG="pass — no test failures detected"
        ANNOTATION_LEVEL="notice"
        ;;
    flake)
        MSG="flake — all ${n_fail} failure(s) are known flakes; auto-rerun queued"
        ANNOTATION_LEVEL="notice"
        ;;
    known-bug)
        _matches=0
        while IFS= read -r _t; do
            [[ -z "$_t" ]] && continue
            echo "$CATALOG_TESTS" | grep -qxF "$_t" && _matches=$(( _matches + 1 )) || true
        done <<< "$FAILURES"
        MSG="known-bug — ${_matches}/${n_fail} failure(s) in KNOWN_FLAKES catalog; remaining are real regressions"
        ANNOTATION_LEVEL="warning"
        ;;
    real)
        MSG="real — ${n_fail} failure(s) not in KNOWN_FLAKES catalog; fix needed"
        ANNOTATION_LEVEL="error"
        ;;
    unknown)
        MSG="unknown — failure detected but no 'FAILED' test lines parseable; investigate CI log"
        ANNOTATION_LEVEL="warning"
        ;;
esac

# ── Emit ──────────────────────────────────────────────────────────────────
echo "triage: $MSG"

ANNOTATE="${CHUMP_TRIAGE_ANNOTATE:-1}"
if [[ "${GITHUB_ACTIONS:-}" == "true" && "$ANNOTATE" == "1" ]]; then
    echo "::${ANNOTATION_LEVEL}::CI triage (CREDIBLE-013): $MSG"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        printf '### CI failure triage\n\n**%s**: %s\n' "$CLASS" "$MSG" >> "$GITHUB_STEP_SUMMARY"
        if [[ -n "$FAILURES" && "$CLASS" != "pass" ]]; then
            printf '\nFailing tests:\n```\n%s\n```\n' "$FAILURES" >> "$GITHUB_STEP_SUMMARY"
        fi
    fi
fi

# ── Exit code ─────────────────────────────────────────────────────────────
case "$CLASS" in
    pass|flake) exit 0 ;;
    *)          exit 1 ;;
esac
