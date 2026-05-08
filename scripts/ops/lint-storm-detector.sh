#!/usr/bin/env bash
# lint-storm-detector.sh — INFRA-672: auto-relax clippy lints when 3+ open PRs
# fail on the same lint name within 1h.
#
# What it does. Walks open PRs, checks their CI status for clippy failures,
# and groups by lint name. When the same lint fails on 3+ distinct PRs,
# files an INFRA gap titled "ZERO-WASTE: relax <lint_name> at workspace.lints.clippy"
# with P0 priority and xs effort. De-dups by checking for existing open gaps
# with the same lint name in the title.
#
# Usage:
#   scripts/ops/lint-storm-detector.sh                # live run
#   scripts/ops/lint-storm-detector.sh --dry-run      # print what would be filed
#
# Environment:
#   CHUMP_LINT_STORM_DETECTOR=0  bypass — exit 0 immediately
#   LINT_STORM_THRESHOLD         min PRs per lint to file gap (default: 3)
#   LINT_STORM_HOUR_WINDOW       time window in hours (default: 1)
#
# Wired to run hourly via launchd (see scripts/setup/install-ambient-hooks.sh).

set -euo pipefail

if [[ "${CHUMP_LINT_STORM_DETECTOR:-1}" == "0" ]]; then
    echo "[lint-storm-detector] CHUMP_LINT_STORM_DETECTOR=0 — bypass"
    exit 0
fi

# shellcheck source=../lib/reaper-instrumentation.sh
source "$(dirname "$0")/../lib/reaper-instrumentation.sh"
reaper_setup lint-storm
reaper_check_disk_headroom
reaper_rotate_log /tmp/chump-lint-storm-detector.out.log
reaper_rotate_log /tmp/chump-lint-storm-detector.err.log
trap 'rc=$?; [[ $rc -ne 0 ]] && reaper_finish fail "{\"exit\":$rc}"' EXIT

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

LINT_STORM_THRESHOLD="${LINT_STORM_THRESHOLD:-3}"
LINT_STORM_HOUR_WINDOW="${LINT_STORM_HOUR_WINDOW:-1}"

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
warn()  { printf '\033[0;33m  WARN: %s\033[0m\n' "$*"; }
dry()   { printf '  [dry-run] %s\n' "$*"; }

green "=== lint-storm-detector (threshold: $LINT_STORM_THRESHOLD, window: ${LINT_STORM_HOUR_WINDOW}h) ==="
[[ $DRY_RUN -eq 1 ]] && info "Dry-run mode — no gaps will be filed."

# Existing ZERO-WASTE lint gaps keyed by lint name. Pattern: "relax <name> at workspace.lints.clippy"
EXISTING_GAPS=""
if command -v chump >/dev/null 2>&1; then
    EXISTING_GAPS=$(chump gap list --status open --json 2>/dev/null \
        | python3 -c "
import json, sys, re
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in rows:
    title = r.get('title') or ''
    m = re.search(r'relax\s+(\S+)\s+at\s+workspace\.lints\.clippy', title)
    if m:
        print(m.group(1))
" 2>/dev/null || true)
fi

gap_exists_for_lint() {
    local lint="$1"
    [[ -n "$EXISTING_GAPS" ]] || return 1
    grep -qx "$lint" <<<"$EXISTING_GAPS"
}

# get_clippy_failures_for_pr PR_NUM [RUN_ID]
# Fetches CI logs and extracts clippy lint names (e.g., "clippy::lint_name").
# Returns one lint per line. If RUN_ID is provided, only checks that run.
get_clippy_failures_for_pr() {
    local pr="$1"
    local specific_run="${2:-}"
    local runs=""

    if [[ -n "$specific_run" ]]; then
        runs="$specific_run"
    else
        # Get all run IDs for this PR from recent workflow runs.
        runs=$(gh run list --repo "$(git config --get remote.origin.url | sed 's|.*/\([^/]*\)/\([^/]*\)\.git$|\1/\2|')" \
            --status "failure" --branch ".*" --limit 10 2>/dev/null \
            | awk '{print $1}' | head -5 || true)
    fi

    [[ -z "$runs" ]] && return 0

    while IFS= read -r run_id; do
        [[ -z "$run_id" ]] && continue
        # Fetch the log for this run and grep for clippy lint patterns.
        # Clippy errors typically show: "error[clippy::<lint>]:" or "-W clippy::<lint>"
        gh run view "$run_id" --log 2>/dev/null | grep -oE 'clippy::[a-z_]+' || true
    done <<<"$runs"
}

# file_lint_gap LINT_NAME COUNT PR_NUMS
file_lint_gap() {
    local lint="$1"
    local count="$2"
    local pr_nums="$3"

    if gap_exists_for_lint "$lint"; then
        info "  ZERO-WASTE gap for clippy::$lint already exists — skipping"
        return
    fi

    local title="ZERO-WASTE: relax $lint at workspace.lints.clippy"

    if [[ $DRY_RUN -eq 1 ]]; then
        dry "would file: $title"
        dry "  ($count PRs: #${pr_nums// /, #})"
        FILED=$((FILED + 1))
        return
    fi

    if ! command -v chump >/dev/null 2>&1; then
        warn "chump binary not on PATH — cannot file gap for clippy::$lint"
        return
    fi

    local reserved
    reserved=$(chump gap reserve --domain INFRA --title "$title" \
        --priority P0 --effort xs 2>&1 | tail -1)
    if [[ ! "$reserved" =~ ^INFRA-[0-9]+$ ]]; then
        warn "chump gap reserve failed for clippy::$lint: $reserved"
        return
    fi
    info "  filed $reserved: $title"

    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local desc
    desc="Lint-storm auto-detected by lint-storm-detector (${ts}).

Lint:        clippy::${lint}
Affected PRs: ${count} (#${pr_nums// /, #})

Action:
  1. Review the clippy lint documentation: https://rust-lang.github.io/rust-clippy/
  2. Determine if the lint should be relaxed fleet-wide in workspace.lints.clippy
  3. If yes: add the lint to [lints.clippy] or [lints.clippy.pedantic] in Cargo.toml
  4. If no: fix the underlying code issues triggering the lint on multiple PRs

Rationale (INFRA-672):
  When the same lint fails on 3+ PRs, it indicates either:
  a) A new clippy version introduced a lint that's too noisy, or
  b) A codebase-wide pattern that should be relaxed rather than fixed per-PR
  This gap automates the detection of these lint-storms."

    chump gap set "$reserved" --description "$desc" 2>/dev/null || \
        warn "  could not set description on $reserved (gap reserved but bare)"

    # Emit ambient event for monitoring.
    local lock_dir="${REAPER_LOCK_DIR:-.chump-locks}"
    local ambient="$lock_dir/ambient.jsonl"
    printf '{"event":"alert","kind":"lint_storm","ts":"%s","lint":"clippy::%s","pr_count":%s,"prs":[%s],"filed_gap":"%s"}\n' \
        "$ts" "$lint" "$count" "${pr_nums// /,}" "$reserved" >> "$ambient" 2>/dev/null || true

    FILED=$((FILED + 1))
}

# Walk open PRs and collect clippy lint failures.
# Format: pr_num<tab>lint_name (one line per PR-lint pair)
LINT_DATA=$(mktemp /tmp/chump-lint-storm-XXXXXX)

PRS_JSON=$(gh pr list --state open --json number,statusCheckRollup --limit 50 2>/dev/null || echo "[]")
if [[ "$PRS_JSON" == "[]" || -z "$PRS_JSON" ]]; then
    info "No open PRs."
    trap - EXIT
    reaper_finish ok '{"filed":0,"detected":0}'
    exit 0
fi

info "Scanning open PRs for clippy failures..."
PRS=$(echo "$PRS_JSON" | python3 -c "
import json, sys
for p in json.load(sys.stdin):
    num = p.get('number')
    if not num:
        continue
    rollup = p.get('statusCheckRollup') or []
    # Look for failed checks that might have clippy data
    failed = [c for c in rollup if (c.get('conclusion') or '').upper() in ('FAILURE','ERROR','CANCELLED')]
    if failed:
        print(num)
" 2>/dev/null || true)

# Collect clippy lint failures from each PR.
DETECTED=0
while IFS= read -r pr_num; do
    [[ -z "$pr_num" ]] && continue
    info "PR #$pr_num → checking for clippy failures..."

    lints=$(get_clippy_failures_for_pr "$pr_num" 2>/dev/null | sort -u | tr '\n' ' ')
    if [[ -n "$lints" ]]; then
        for lint_full in $lints; do
            # Extract just the lint name from "clippy::lint_name"
            lint="${lint_full#clippy::}"
            [[ -n "$lint" ]] && echo "$pr_num	$lint" >> "$LINT_DATA"
            DETECTED=$((DETECTED + 1))
        done
    fi
done <<<"$PRS"

# Aggregate by lint name and count distinct PRs.
if [[ ! -s "$LINT_DATA" ]]; then
    info "No clippy lint failures detected."
    rm -f "$LINT_DATA"
    trap - EXIT
    reaper_finish ok "{\"filed\":0,\"detected\":0}"
    exit 0
fi

green "Detected $DETECTED clippy lint failures; aggregating by lint name..."

FILED=0

# Python: group by lint, count distinct PRs, emit GROUP/SINGLE directives.
python3 - "$LINT_DATA" "$LINT_STORM_THRESHOLD" <<'PYEOF' | while IFS=$'\t' read -r action lint count pr_list; do
import sys, collections

data_file = sys.argv[1]
threshold = int(sys.argv[2])

groups = collections.defaultdict(set)
with open(data_file) as f:
    for line in f:
        parts = line.rstrip('\n').split('\t')
        if len(parts) < 2:
            continue
        pr_num, lint = parts[0], parts[1]
        if lint:
            groups[lint].add(pr_num)

for lint, pr_set in sorted(groups.items()):
    pr_count = len(pr_set)
    pr_list = ' '.join(sorted(pr_set))
    if pr_count >= threshold:
        print(f"GROUP\t{lint}\t{pr_count}\t{pr_list}")
    else:
        print(f"SINGLE\t{lint}\t{pr_count}\t{pr_list}")
PYEOF
    case "$action" in
        GROUP)
            file_lint_gap "$lint" "$count" "$pr_list"
            ;;
        SINGLE)
            :  # Don't file for single or below-threshold counts
            ;;
    esac
done

rm -f "$LINT_DATA"

echo ""
green "=== lint-storm-detector done: $FILED filed ==="

trap - EXIT
reaper_finish ok "{\"filed\":$FILED,\"detected\":$DETECTED}"
