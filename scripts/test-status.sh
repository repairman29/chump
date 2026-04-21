#!/usr/bin/env bash
# test-status.sh — at-a-glance dashboard of in-flight test runs across the team.
#
# Surfaces:
#   - Live test processes (run.sh, run-cloud-v2.py, multi-model-study.sh, chump --chump)
#   - Recent test summaries from logs/ab/ (last 10, with deltas)
#   - Cost ledger spend (today + lifetime)
#   - Any harness logs in /tmp/* with errors in the last hour
#   - Disk usage of logs/ (so we know when to prune)
#
# No flags. Just run it. Designed to be cheap (~1 sec wall) and read-only.
#
# Usage:
#   scripts/test-status.sh
#
# Pipe to less if the output is long:
#   scripts/test-status.sh | less -R

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# Resolve to MAIN repo when run from a worktree (logs/ live in main)
MAIN_REPO="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree / {print $2; exit}')"
[[ -z "$MAIN_REPO" || ! -d "$MAIN_REPO/logs/ab" ]] && MAIN_REPO="$REPO_ROOT"
cd "$MAIN_REPO"

# ANSI colors (off if not a tty)
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
    YELLOW=$'\033[33m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
    BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; CYAN=''; RESET=''
fi

echo "${BOLD}=== test-status @ $(date -u +%Y-%m-%dT%H:%M:%SZ) ===${RESET}"
echo

# ── 1. Live test processes ────────────────────────────────────────────────────
echo "${BOLD}▸ live test processes${RESET}"
procs=$(ps -axo pid,etime,command 2>/dev/null | \
        grep -E "run-cloud(-v2)?\.py|run-(local-v2|real-tools|real-lessons|cog006-neuromod|queue|multi-model)\.sh|run\.sh|chump --chump" | \
        grep -v grep || true)
if [[ -n "$procs" ]]; then
    echo "$procs" | awk '{
        pid=$1; etime=$2;
        cmd=""; for (i=3; i<=NF && i<=8; i++) cmd = cmd $i " ";
        printf "  %-7s  %-12s %s\n", pid, etime, substr(cmd, 1, 100)
    }' | head -10
    n=$(echo "$procs" | wc -l | tr -d ' ')
    [[ $n -gt 10 ]] && echo "  ${DIM}… ($n total)${RESET}"
else
    echo "  ${DIM}(no live test processes)${RESET}"
fi
echo

# ── 2. Recent A/B summaries (last 10) ────────────────────────────────────────
echo "${BOLD}▸ recent A/B summaries (last 10 by mtime)${RESET}"
summaries=$(ls -t logs/ab/*summary*.json 2>/dev/null | head -10)
if [[ -n "$summaries" ]]; then
    while IFS= read -r s; do
        # Extract delta + model + n from the summary
        info=$(python3 -c "
import json, sys, os
p = '$s'
try:
    d = json.load(open(p))
    n = d.get('trial_count', d.get('task_count', '?'))
    model = d.get('model', '?').replace('claude-', '')
    # v2 delta
    if 'deltas' in d:
        h = d['deltas'].get('hallucinated_tools', {})
        c = d['deltas'].get('is_correct', {})
        sig = ' SIG' if not h.get('cis_overlap', True) else ''
        print(f\"halluc={h.get('delta',0):+.3f}{sig}  correct={c.get('delta',0):+.3f}\")
    # v1 delta
    elif 'delta' in d:
        print(f\"delta={d['delta']:+.3f}\")
    else:
        print('(unknown shape)')
    print(f\"  n={n}  model={model[:25]}\")
except Exception as e:
    print(f'(parse error: {e})')
" 2>/dev/null | head -2)
        name=$(basename "$s" .summary.json)
        when=$(date -r "$s" +"%H:%M:%S" 2>/dev/null || echo "?")
        printf "  ${CYAN}%s${RESET} %-50s\n    %s\n" "$when" "${name:0:50}" "$info"
    done <<< "$summaries"
else
    echo "  ${DIM}(no summaries in logs/ab/)${RESET}"
fi
echo

# ── 3. Cost spend ─────────────────────────────────────────────────────────────
echo "${BOLD}▸ cost ledger${RESET}"
if [[ -f scripts/ab-harness/cost_ledger.py ]]; then
    today=$(date -u +%Y-%m-%d)
    today_total=$(python3 -c "
import sys; sys.path.insert(0, 'scripts/ab-harness')
from cost_ledger import total
t = total(since_iso='$today')
print(f\"today: \${t['all']:.2f} ({t['calls']} calls)\")
" 2>/dev/null)
    lifetime=$(python3.12 scripts/ab-harness/cost_ledger.py --summary 2>/dev/null | head -1)
    echo "  $today_total"
    echo "  $lifetime"
else
    echo "  ${DIM}(cost_ledger.py not on path — earlier merge?)${RESET}"
fi
echo

# ── 4. Harness errors in /tmp/ (last hour) ────────────────────────────────────
echo "${BOLD}▸ recent harness errors (/tmp/*.log, last hour)${RESET}"
recent_err_files=$(find /tmp -maxdepth 1 -name "*.log" -mmin -60 2>/dev/null \
    -exec grep -l -E "Error|Exception|FAIL|429|RemoteDisconnected" {} \; 2>/dev/null | head -5)
if [[ -n "$recent_err_files" ]]; then
    while IFS= read -r f; do
        first_err=$(grep -m1 -E "Error|Exception|FAIL|429" "$f" 2>/dev/null | head -c 80)
        echo "  ${RED}$(basename $f)${RESET}: $first_err"
    done <<< "$recent_err_files"
else
    echo "  ${GREEN}(no errors in last hour)${RESET}"
fi
echo

# ── 5. Disk usage ─────────────────────────────────────────────────────────────
echo "${BOLD}▸ logs/ disk usage${RESET}"
if [[ -d logs ]]; then
    total_size=$(du -sh logs 2>/dev/null | awk '{print $1}')
    n_jsonl=$(find logs -name "*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
    n_summary=$(find logs -name "*summary*.json" 2>/dev/null | wc -l | tr -d ' ')
    echo "  $total_size total · $n_jsonl jsonl · $n_summary summaries"
else
    echo "  ${DIM}(no logs/ dir)${RESET}"
fi
echo

# ── 6. Open PRs (mine — author=$USER) ─────────────────────────────────────────
echo "${BOLD}▸ open PRs in the repo${RESET}"
pr_count=$(gh pr list --json number 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "?")
echo "  $pr_count open"
gh pr list --limit 5 --json number,title,mergeStateStatus -q '.[] | "  PR #\(.number) \(.mergeStateStatus[:10]): \(.title[:60])"' 2>/dev/null || \
    echo "  ${DIM}(gh not available or auth missing)${RESET}"
