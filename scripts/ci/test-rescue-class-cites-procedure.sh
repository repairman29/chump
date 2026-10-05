#!/usr/bin/env bash
# test-rescue-class-cites-procedure.sh — META-249 (META-247 slice)
#
# Gate: any PR whose title matches a rescue-class pattern (fix(...rescue),
# fix(...trunk-red), unblock, fix(...allowlist), filed-by-pr-shepherd) must
# cite BOTH '§5' (Failure-surface taxonomy) and '§6' (Cascade impact tables)
# of docs/process/PR_RESCUE_PROCEDURE.md in the PR body. Rescue work that
# skips the procedure doc tends to re-diagnose failure surfaces that are
# already catalogued there (see test-pr-rescue-procedure-doc.sh, META-246).
#
# Usage:
#   scripts/ci/test-rescue-class-cites-procedure.sh [<pr-number>]
#     <pr-number>   optional; defaults to the PR for the current branch
#                   (gh pr view with no args). Falls back to
#                   $GITHUB_EVENT_PATH's pull_request.number when unset.
#
#   scripts/ci/test-rescue-class-cites-procedure.sh --self-test
#     Runs the embedded fixture scenarios (rescue-class PASS, rescue-class
#     FAIL, non-rescue-class SKIP) against a mocked `gh`. Exits 0 only if
#     all scenarios behave as expected.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/gate-emit.sh
source "$SCRIPT_DIR/lib/gate-emit.sh" 2>/dev/null || true

RESCUE_TITLE_PATTERN='fix\([^)]*rescue[^)]*\)|fix\([^)]*trunk-red[^)]*\)|unblock|fix\([^)]*allowlist[^)]*\)|filed-by-pr-shepherd'

is_rescue_class() {
    echo "$1" | grep -qiE "$RESCUE_TITLE_PATTERN"
}

# check_pr_body <title> <body> — echoes PASS/FAIL/SKIP, sets $? accordingly.
check_citations() {
    local title="$1" body="$2"

    if ! is_rescue_class "$title"; then
        echo "SKIP: title '$title' does not match rescue-class patterns"
        return 0
    fi

    local missing=()
    echo "$body" | grep -qF '§5' || missing+=("§5 (Failure-surface taxonomy)")
    echo "$body" | grep -qF '§6' || missing+=("§6 (Cascade impact tables)")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "FAIL: rescue-class PR is missing citation(s): ${missing[*]}"
        echo "      Remediation: cite the specific section(s) of"
        echo "      docs/process/PR_RESCUE_PROCEDURE.md this rescue used —"
        echo "      e.g. 'Per PR_RESCUE_PROCEDURE.md §5 (Allowlist drift) and"
        echo "      §6 (Cascade impact)...' — in the PR body."
        return 1
    fi

    echo "PASS: rescue-class PR '$title' cites both §5 and §6"
    return 0
}

run_self_test() {
    local pass=0 fail=0 rc out

    ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
    bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }

    echo "=== META-249 test-rescue-class-cites-procedure self-test ==="

    # Scenario 1: rescue-class title, both citations present → PASS
    rc=0
    out="$(check_citations 'fix(bot-merge-rescue): re-arm stalled auto-merge' \
        'Per PR_RESCUE_PROCEDURE.md §5 (Allowlist drift) and §6 (Cascade impact tables), this re-arms the auto-merge label.' \
        2>&1)" || rc=$?
    if [[ $rc -eq 0 ]] && echo "$out" | grep -q '^PASS'; then
        ok "Scenario 1: rescue-class + both citations → PASS"
    else
        bad "Scenario 1: expected PASS, got (rc=$rc): $out"
    fi

    # Scenario 2: rescue-class title, missing §6 → FAIL
    rc=0
    out="$(check_citations 'fix(queue-driver): unblock stuck BEHIND PRs' \
        'Per PR_RESCUE_PROCEDURE.md §5 (Allowlist drift), rebased and re-armed.' \
        2>&1)" || rc=$?
    if [[ $rc -eq 1 ]] && echo "$out" | grep -q '^FAIL' && echo "$out" | grep -q '§6'; then
        ok "Scenario 2: rescue-class + missing §6 → FAIL"
    else
        bad "Scenario 2: expected FAIL citing §6, got (rc=$rc): $out"
    fi

    # Scenario 3: rescue-class title, no citations at all → FAIL
    rc=0
    out="$(check_citations 'fix(ci-allowlist): add missing script to allowlist' \
        'Adds the script to the allowlist so CI passes.' \
        2>&1)" || rc=$?
    if [[ $rc -eq 1 ]] && echo "$out" | grep -q '§5' && echo "$out" | grep -q '§6'; then
        ok "Scenario 3: rescue-class + no citations → FAIL (both cited as missing)"
    else
        bad "Scenario 3: expected FAIL citing both §5 and §6, got (rc=$rc): $out"
    fi

    # Scenario 4: non-rescue-class title → SKIP regardless of body
    rc=0
    out="$(check_citations 'feat: add new dashboard tile' 'no citations here' 2>&1)" || rc=$?
    if [[ $rc -eq 0 ]] && echo "$out" | grep -q '^SKIP'; then
        ok "Scenario 4: non-rescue-class title → SKIP"
    else
        bad "Scenario 4: expected SKIP, got (rc=$rc): $out"
    fi

    # Scenario 5: filed-by-pr-shepherd title, both citations → PASS
    rc=0
    out="$(check_citations 'chore: filed-by-pr-shepherd cluster fix' \
        'See §5 and §6 of the procedure doc for the failure signature.' \
        2>&1)" || rc=$?
    if [[ $rc -eq 0 ]] && echo "$out" | grep -q '^PASS'; then
        ok "Scenario 5: filed-by-pr-shepherd + both citations → PASS"
    else
        bad "Scenario 5: expected PASS, got (rc=$rc): $out"
    fi

    echo
    echo "=== Self-test results: $pass passed, $fail failed ==="
    [[ $fail -eq 0 ]]
}

main() {
    if [[ "${1:-}" == "--self-test" ]]; then
        run_self_test
        exit $?
    fi

    gate_emit_start "META-249" "$*"

    local pr_number="${1:-}"
    if [[ -z "$pr_number" && -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH:-}" ]]; then
        pr_number="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('pull_request',{}).get('number','') )" "$GITHUB_EVENT_PATH" 2>/dev/null || true)"
    fi

    if ! command -v gh &>/dev/null; then
        echo "[rescue-class-cites-procedure] WARN: gh CLI not available — skipping" >&2
        gate_emit_result "META-249" "skipped" "" "gh CLI unavailable"
        exit 0
    fi

    local pr_json title body
    if [[ -n "$pr_number" ]]; then
        pr_json="$(gh pr view "$pr_number" --json title,body 2>/dev/null || true)"
    else
        pr_json="$(gh pr view --json title,body 2>/dev/null || true)"
    fi

    if [[ -z "$pr_json" ]]; then
        echo "[rescue-class-cites-procedure] WARN: could not resolve PR context — skipping" >&2
        gate_emit_result "META-249" "skipped" "" "no PR context"
        exit 0
    fi

    title="$(echo "$pr_json" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('title',''))" 2>/dev/null || true)"
    body="$(echo "$pr_json" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('body',''))" 2>/dev/null || true)"

    local out rc=0
    out="$(check_citations "$title" "$body")" || rc=$?
    echo "$out"

    if [[ $rc -ne 0 ]]; then
        gate_emit_result "META-249" "fail" "missing-citation" "$out"
        exit 1
    fi

    gate_emit_result "META-249" "pass" "" ""
    exit 0
}

main "$@"
