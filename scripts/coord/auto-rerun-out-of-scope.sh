#!/usr/bin/env bash
# auto-rerun-out-of-scope.sh — INFRA-1003
#
# When a PR check fails on tests that are entirely outside the PR's diff
# scope, rerun once. Rationale: a 2-file shell-only diff that breaks a
# Rust unit test is almost certainly an environmental flake or pre-existing
# main regression, not a real regression caused by this PR.
#
# Heuristic, not authoritative. Conservative defaults:
#   - At most 1 auto-rerun per PR per 24 h (budget guard)
#   - Overlap check is conservative: any overlap → no rerun
#   - Dry-run by default
#
# Usage:
#   scripts/coord/auto-rerun-out-of-scope.sh <PR-number>
#   scripts/coord/auto-rerun-out-of-scope.sh <PR-number> --execute
#   scripts/coord/auto-rerun-out-of-scope.sh <PR-number> --dry-run   (default)
#
# Environment:
#   CHUMP_AUTO_RERUN_OOS=0        bypass — exit 0 immediately
#   REPO                          owner/repo for gh calls (default: inferred)
#   AMBIENT_JSONL                 path to ambient stream (default: .chump-locks/ambient.jsonl)

set -uo pipefail

if [[ "${CHUMP_AUTO_RERUN_OOS:-1}" == "0" ]]; then
    echo "[auto-rerun-oos] CHUMP_AUTO_RERUN_OOS=0 — bypass"
    exit 0
fi

PR="${1:?Usage: $0 <PR-number> [--execute|--dry-run]}"
shift || true

DRY_RUN=true
for arg in "$@"; do
    case "$arg" in
        --execute) DRY_RUN=false ;;
        --dry-run) DRY_RUN=true ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AMBIENT="${AMBIENT_JSONL:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"

# ── Per-PR budget guard: 1 rerun per PR per 24 h ─────────────────────────────
BUDGET_DIR="${CHUMP_OOS_BUDGET_DIR:-${REPO_ROOT}/.chump-locks/oos-rerun-budget}"
mkdir -p "$BUDGET_DIR" 2>/dev/null || true
BUDGET_FILE="${BUDGET_DIR}/pr-${PR}.ts"
if [[ -f "$BUDGET_FILE" ]]; then
    LAST_TS="$(cat "$BUDGET_FILE" 2>/dev/null || echo 0)"
    NOW="$(date +%s)"
    AGE=$(( NOW - LAST_TS ))
    if [[ "$AGE" -lt 86400 ]]; then
        echo "[auto-rerun-oos] PR #${PR}: budget exhausted (last rerun ${AGE}s ago < 86400s). Skipping."
        exit 0
    fi
fi

# ── Fetch PR diff paths ───────────────────────────────────────────────────────
REPO_FLAG=""
[[ -n "${REPO:-}" ]] && REPO_FLAG="--repo $REPO"
# shellcheck disable=SC2086
DIFF_PATHS="$(gh pr view "$PR" $REPO_FLAG --json files 2>/dev/null \
    | python3 -c "import sys,json; [print(f['path']) for f in json.load(sys.stdin).get('files',[])]" 2>/dev/null || true)"
if [[ -z "$DIFF_PATHS" ]]; then
    echo "[auto-rerun-oos] PR #${PR}: could not fetch diff paths — skipping"
    exit 0
fi

# ── Fetch failing checks (run IDs) ───────────────────────────────────────────
# shellcheck disable=SC2086
CHECKS_JSON="$(gh pr checks "$PR" $REPO_FLAG --json name,conclusion,databaseId 2>/dev/null || true)"
if [[ -z "$CHECKS_JSON" ]]; then
    echo "[auto-rerun-oos] PR #${PR}: could not fetch checks — skipping"
    exit 0
fi
FAILED_RUNS="$(echo "$CHECKS_JSON" | python3 -c "
import sys, json
checks = json.load(sys.stdin)
failed = [c for c in checks if c.get('conclusion') in ('failure', 'timed_out')]
for c in failed:
    print(c.get('databaseId', ''))
" 2>/dev/null | grep -v '^$' || true)"

if [[ -z "$FAILED_RUNS" ]]; then
    echo "[auto-rerun-oos] PR #${PR}: no failing checks — nothing to do"
    exit 0
fi

echo "[auto-rerun-oos] PR #${PR}: ${#DIFF_PATHS} diff-path chars, failing run IDs: $(echo "$FAILED_RUNS" | tr '\n' ' ')"

# ── For each failing run, collect failing test source paths ──────────────────

_map_test_to_source() {
    local test_name="$1"
    # Shell test script: name matches scripts/ci/test-*.sh or scripts/coord/test-*.sh
    if [[ "$test_name" =~ ^test- ]]; then
        for prefix in "scripts/ci" "scripts/coord" "scripts/ops"; do
            local candidate="${prefix}/${test_name}"
            [[ "${candidate}" != *.sh ]] && candidate="${candidate}.sh"
            if [[ -f "${REPO_ROOT}/${candidate}" ]]; then
                echo "$candidate"
                return
            fi
        done
    fi
    # Rust test: module::test_name (contains ::) → grep for it in src/
    if [[ "$test_name" == *::* ]]; then
        local fn_name="${test_name##*::}"
        local found
        found="$(grep -rl "fn ${fn_name}" "${REPO_ROOT}/src/" 2>/dev/null | head -3 | sed "s|${REPO_ROOT}/||" || true)"
        if [[ -n "$found" ]]; then
            echo "$found"
            return
        fi
    fi
    # GitHub Actions job name → look for .github/workflows/*.yml with the job
    if [[ -d "${REPO_ROOT}/.github/workflows" ]]; then
        local wf_match
        wf_match="$(grep -rl "name:.*${test_name}" "${REPO_ROOT}/.github/workflows/" 2>/dev/null | head -1 | sed "s|${REPO_ROOT}/||" || true)"
        [[ -n "$wf_match" ]] && echo "$wf_match"
    fi
}

ALL_RERUN_RUN_IDS=()
ALL_OOS_EVIDENCE=()

for run_id in $FAILED_RUNS; do
    [[ -z "$run_id" ]] && continue
    # shellcheck disable=SC2086
    JOBS_JSON="$(gh run view "$run_id" $REPO_FLAG --json jobs 2>/dev/null || true)"
    if [[ -z "$JOBS_JSON" ]]; then
        echo "[auto-rerun-oos]   run $run_id: could not fetch jobs — skipping"
        continue
    fi

    FAILING_JOBS="$(echo "$JOBS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for job in data.get('jobs', []):
    if job.get('conclusion') in ('failure', 'timed_out'):
        print(job.get('name', ''))
" 2>/dev/null || true)"

    HAS_OVERLAP=false
    JOB_SOURCES=()

    while IFS= read -r job_name; do
        [[ -z "$job_name" ]] && continue
        sources="$(_map_test_to_source "$job_name")"
        if [[ -n "$sources" ]]; then
            while IFS= read -r src; do
                JOB_SOURCES+=("$src")
                # Check overlap with diff paths
                if echo "$DIFF_PATHS" | grep -qxF "$src" 2>/dev/null; then
                    HAS_OVERLAP=true
                fi
            done <<< "$sources"
        else
            # Unknown mapping → be conservative, assume overlap
            echo "[auto-rerun-oos]   run $run_id, job '$job_name': no source mapping — assuming overlap (conservative)"
            HAS_OVERLAP=true
        fi
    done <<< "$FAILING_JOBS"

    if [[ "$HAS_OVERLAP" == "false" && ${#JOB_SOURCES[@]} -gt 0 ]]; then
        echo "[auto-rerun-oos]   run $run_id: OUT-OF-SCOPE — diff doesn't touch failing tests (${JOB_SOURCES[*]})"
        ALL_RERUN_RUN_IDS+=("$run_id")
        ALL_OOS_EVIDENCE+=("${JOB_SOURCES[*]}")
    else
        echo "[auto-rerun-oos]   run $run_id: IN-SCOPE or unknown — not eligible for OOS rerun"
    fi
done

if [[ ${#ALL_RERUN_RUN_IDS[@]} -eq 0 ]]; then
    echo "[auto-rerun-oos] PR #${PR}: no out-of-scope failures found"
    exit 0
fi

# ── Rerun out-of-scope failing runs ──────────────────────────────────────────
RERAN=0
for i in "${!ALL_RERUN_RUN_IDS[@]}"; do
    run_id="${ALL_RERUN_RUN_IDS[$i]}"
    evidence="${ALL_OOS_EVIDENCE[$i]:-}"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[auto-rerun-oos] DRY-RUN: would rerun run_id=$run_id (evidence: $evidence)"
        RERAN=$((RERAN+1))
    else
        # shellcheck disable=SC2086
        if gh run rerun "$run_id" --failed $REPO_FLAG 2>/dev/null; then
            echo "[auto-rerun-oos] RERUN: run_id=$run_id triggered"
            RERAN=$((RERAN+1))
            # Record budget stamp
            date +%s > "$BUDGET_FILE"
            # Emit ambient event
            TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            DIFF_PATHS_JSON="$(echo "$DIFF_PATHS" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().splitlines()))' 2>/dev/null || echo '[]')"
            EVIDENCE_JSON="$(echo "$evidence" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().split()))' 2>/dev/null || echo '[]')"
            printf '{"ts":"%s","kind":"auto_rerun_out_of_scope","pr_number":%s,"run_id":"%s","diff_paths":%s,"failing_tests":%s}\n' \
                "$TS" "$PR" "$run_id" "$DIFF_PATHS_JSON" "$EVIDENCE_JSON" \
                >> "$AMBIENT" 2>/dev/null || true
        else
            echo "[auto-rerun-oos] ERROR: gh run rerun $run_id failed"
        fi
    fi
done

echo "[auto-rerun-oos] PR #${PR}: reran=$RERAN out-of-scope run(s); dry_run=$DRY_RUN"
