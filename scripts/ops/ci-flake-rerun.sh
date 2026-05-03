#!/usr/bin/env bash
# ci-flake-rerun.sh — INFRA-375: pattern-match known CI flakes on open
# PRs and auto-rerun their failed jobs once.
#
# Each PR gets at most ONE auto-rerun per failing run-id (cooldown record).
# Real failures retry once, fail again, and are then left alone for human/
# stuck-pr-filer. Only matches against a tight allowlist of flake patterns
# observed in this repo's CI logs:
#
#   - "##[error]The operation was canceled" (runner cancel)
#   - "Error: getaddrinfo EAI_AGAIN" (DNS hiccup)
#   - "Error: connect ETIMEDOUT" (transient network)
#   - "fatal: unable to access" (git network)
#   - "rustup: command not found" (toolchain race in setup)
#   - "Process completed with exit code 137" (OOM kill)
#
# Real test failures don't match → no rerun → no waste.
#
# Usage:
#   scripts/ops/ci-flake-rerun.sh                # live run
#   scripts/ops/ci-flake-rerun.sh --dry-run      # print what would rerun
#
# Environment:
#   CHUMP_CI_FLAKE_RERUN=0       bypass — exit 0 immediately
#   CI_FLAKE_PATTERNS_FILE       path to extra patterns (one per line)
#
# Wired into reaper-heartbeat-watchdog (1h threshold, hourly cadence).

set -euo pipefail

if [[ "${CHUMP_CI_FLAKE_RERUN:-1}" == "0" ]]; then
    echo "[ci-flake-rerun] CHUMP_CI_FLAKE_RERUN=0 — bypass"
    exit 0
fi

# shellcheck source=../lib/reaper-instrumentation.sh
source "$(dirname "$0")/../lib/reaper-instrumentation.sh"
reaper_setup ci-flake
reaper_rotate_log /tmp/chump-ci-flake-rerun.out.log
reaper_rotate_log /tmp/chump-ci-flake-rerun.err.log
trap 'rc=$?; [[ $rc -ne 0 ]] && reaper_finish fail "{\"exit\":$rc}"' EXIT

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

COOLDOWN_DIR="$REAPER_REPO_ROOT/.chump-locks/ci-flake-cooldown"
mkdir -p "$COOLDOWN_DIR" 2>/dev/null || true

# Tight allowlist of flake fingerprints (extended via CI_FLAKE_PATTERNS_FILE).
FLAKE_PATTERNS=(
    'The operation was canceled'
    'getaddrinfo EAI_AGAIN'
    'connect ETIMEDOUT'
    'fatal: unable to access'
    'rustup: command not found'
    'Process completed with exit code 137'
    'Network is unreachable'
    'temporarily unavailable'
)
if [[ -n "${CI_FLAKE_PATTERNS_FILE:-}" && -f "$CI_FLAKE_PATTERNS_FILE" ]]; then
    while IFS= read -r line; do
        [[ -n "$line" && "$line" != \#* ]] && FLAKE_PATTERNS+=("$line")
    done < "$CI_FLAKE_PATTERNS_FILE"
fi

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
warn()  { printf '\033[0;33m  WARN: %s\033[0m\n' "$*"; }
dry()   { printf '  [dry-run] %s\n' "$*"; }

green "=== ci-flake-rerun ==="
[[ $DRY_RUN -eq 1 ]] && info "Dry-run mode — no jobs will be rerun."

PRS_JSON=$(gh pr list --state open --json number,title,headRefName,statusCheckRollup --limit 50 2>/dev/null || echo "[]")
if [[ "$PRS_JSON" == "[]" || -z "$PRS_JSON" ]]; then
    info "No open PRs."
    trap - EXIT
    reaper_finish ok '{"reran":0,"skipped":0}'
    exit 0
fi

RERAN=0; SKIPPED=0

# Walk PRs → for each, find run-IDs of failing required checks → fetch
# the failed log → grep for any flake pattern → if any match, rerun once.
PRS=$(echo "$PRS_JSON" | python3 -c "
import json,sys
for p in json.load(sys.stdin):
    rollup = p.get('statusCheckRollup') or []
    failed = [c for c in rollup if (c.get('conclusion') or '').upper() in ('FAILURE','ERROR','CANCELLED','TIMED_OUT')]
    if not failed:
        continue
    # Get unique run IDs from URLs like /actions/runs/<RUN_ID>/job/<JOB_ID>
    runs = set()
    for c in failed:
        url = c.get('targetUrl') or c.get('detailsUrl') or ''
        import re
        m = re.search(r'/actions/runs/(\d+)/', url)
        if m:
            runs.add(m.group(1))
    for r in runs:
        print(f\"{p['number']}\t{r}\t{p['title'][:60]}\")
")

while IFS=$'\t' read -r PR_NUM RUN_ID TITLE; do
    [[ -z "$PR_NUM" || -z "$RUN_ID" ]] && continue

    # Cooldown: have we already attempted rerun on this run-id?
    cd_file="$COOLDOWN_DIR/run-${RUN_ID}.ts"
    if [[ -f "$cd_file" ]]; then
        info "PR #$PR_NUM run $RUN_ID: skip (already attempted rerun)"
        SKIPPED=$((SKIPPED+1))
        continue
    fi

    # Pull the failed-log payload and grep for known flakes.
    log=$(gh run view "$RUN_ID" --log-failed 2>/dev/null | head -c 200000)
    matched=""
    for pat in "${FLAKE_PATTERNS[@]}"; do
        if grep -qF "$pat" <<<"$log"; then
            matched="$pat"
            break
        fi
    done

    if [[ -z "$matched" ]]; then
        info "PR #$PR_NUM run $RUN_ID: no flake-pattern match — leaving alone  ($TITLE)"
        SKIPPED=$((SKIPPED+1))
        continue
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        dry "would rerun PR #$PR_NUM run $RUN_ID (matched: '$matched')  ($TITLE)"
        RERAN=$((RERAN+1))
        continue
    fi

    if gh run rerun "$RUN_ID" --failed >/dev/null 2>&1; then
        date +%s > "$cd_file"
        green "  reran PR #$PR_NUM run $RUN_ID (matched flake: '$matched')"
        RERAN=$((RERAN+1))
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        printf '{"event":"alert","kind":"ci_flake_rerun","ts":"%s","pr":%s,"run":"%s","pattern":%s}\n' \
            "$ts" "$PR_NUM" "$RUN_ID" \
            "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$matched" 2>/dev/null || echo "\"$matched\"")" \
            >> "$REAPER_LOCK_DIR/ambient.jsonl" 2>/dev/null || true
    else
        warn "PR #$PR_NUM run $RUN_ID: gh run rerun failed"
        SKIPPED=$((SKIPPED+1))
    fi
done <<<"$PRS"

echo ""
green "=== ci-flake-rerun done: $RERAN reran, $SKIPPED skipped ==="

trap - EXIT
reaper_finish ok "{\"reran\":$RERAN,\"skipped\":$SKIPPED}"
