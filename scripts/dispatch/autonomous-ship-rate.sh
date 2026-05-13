#!/usr/bin/env bash
# autonomous-ship-rate.sh — CREDIBLE-047: autonomous PR ship-rate metric
#
# Computes: % of fleet-filed PRs that merged with zero operator touch.
#
# "Fleet-filed" = PR whose first commit author email is a fleet-agent identity:
#   t@t.t                   — fleet-dispatcher (chump --execute-gap / bot-merge.sh)
#   noreply@anthropic.com   — Claude Code IDE
#   *@users.noreply.github.com (authored by fleet bots)
#   OR PR body contains fleet markers (🤖 Generated with Claude Code)
#
# "Autonomous" = fleet-filed AND:
#   (a) No jeffadkins1@gmail.com commit after the first fleet commit
#   (b) No review/comment/approval by jeffadkins
#
# Output:
#   - stdout: human-readable summary
#   - ~/.chump/metrics/autonomous-ship-rate.jsonl: daily rows (append-only)
#   - ambient.jsonl: kind=autonomous_ship_rate_regression if rate drops >10pp
#
# Usage:
#   bash scripts/dispatch/autonomous-ship-rate.sh               # last 20 PRs, 24h window
#   bash scripts/dispatch/autonomous-ship-rate.sh --limit 50    # last 50 PRs
#   bash scripts/dispatch/autonomous-ship-rate.sh --json        # JSON output
#   bash scripts/dispatch/autonomous-ship-rate.sh --dry-run     # no writes

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then MAIN_REPO="$REPO_ROOT"; else MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"; fi

AMBIENT="${CHUMP_AMBIENT_LOG:-$MAIN_REPO/.chump-locks/ambient.jsonl}"
METRICS_DIR="${CHUMP_METRICS_DIR:-$HOME/.chump/metrics}"
METRICS_FILE="$METRICS_DIR/autonomous-ship-rate.jsonl"

# Fleet author identity markers.
FLEET_EMAILS="t@t.t noreply@anthropic.com"
FLEET_EMAIL_PATTERN="(t@t\.t|noreply@anthropic\.com)"
FLEET_BODY_MARKER="Generated with \[Claude Code\]"
OPERATOR_EMAIL="${CHUMP_OPERATOR_EMAIL:-jeffadkins1@gmail.com}"
OPERATOR_LOGIN="${CHUMP_OPERATOR_LOGIN:-jeffadkins}"

LIMIT=20
AS_JSON=0
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --limit)    LIMIT="$2"; shift 2 ;;
        --json)     AS_JSON=1; shift ;;
        --dry-run)  DRY_RUN=1; shift ;;
        *)          echo "[autonomous-ship-rate] unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Detect repo slug.
REPO_SLUG="$(git -C "$MAIN_REPO" remote get-url origin 2>/dev/null \
    | sed -E 's|.*github.com[:/]||; s|\.git$||')" || REPO_SLUG=""

if [[ -z "$REPO_SLUG" ]] || ! command -v gh &>/dev/null; then
    echo "[autonomous-ship-rate] ERROR: need gh CLI and a GitHub remote" >&2
    exit 1
fi

TODAY="$(date -u +%Y-%m-%d)"

# ── Fetch last N merged PRs ────────────────────────────────────────────────
MERGED_PRS="$(gh api "repos/$REPO_SLUG/pulls?state=closed&sort=updated&direction=desc&per_page=$LIMIT" \
    --jq '[.[] | select(.merged_at != null) | {number: .number, title: .title, body: .body, merged_at: .merged_at, user: .user.login}]' \
    2>/dev/null || echo '[]')"

TOTAL_PR_COUNT="$(echo "$MERGED_PRS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)"

if [[ "$TOTAL_PR_COUNT" -eq 0 ]]; then
    echo "[autonomous-ship-rate] No merged PRs found (offline or empty repo)" >&2
    exit 0
fi

# ── Classify each PR ────────────────────────────────────────────────────────
FLEET_FILED=0
AUTONOMOUS=0

while IFS= read -r pr_json; do
    pr_num="$(echo "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])" 2>/dev/null)"
    pr_body="$(echo "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('body') or '')" 2>/dev/null)"
    pr_user="$(echo "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['user'])" 2>/dev/null)"

    # Step 1: is this fleet-filed?
    # Check PR body for fleet marker, OR check first commit author.
    is_fleet=0
    if echo "$pr_body" | grep -qE "$FLEET_BODY_MARKER"; then
        is_fleet=1
    else
        # Check first commit author via commits API.
        first_commit_email="$(gh api "repos/$REPO_SLUG/pulls/$pr_num/commits?per_page=1" \
            --jq '.[0].commit.author.email // ""' 2>/dev/null || echo "")"
        if echo "$first_commit_email" | grep -qE "$FLEET_EMAIL_PATTERN"; then
            is_fleet=1
        fi
    fi

    [[ "$is_fleet" -eq 0 ]] && continue
    FLEET_FILED=$((FLEET_FILED + 1))

    # Step 2: is it autonomous? Check for operator involvement.
    # (a) Any operator commit in the branch?
    op_commits="$(gh api "repos/$REPO_SLUG/pulls/$pr_num/commits?per_page=100" \
        --jq "[.[] | .commit.author.email] | map(select(. == \"$OPERATOR_EMAIL\")) | length" 2>/dev/null || echo 0)"

    # (b) Any operator review or comment?
    op_reviews="$(gh api "repos/$REPO_SLUG/pulls/$pr_num/reviews?per_page=50" \
        --jq "[.[] | .user.login] | map(select(. == \"$OPERATOR_LOGIN\")) | length" 2>/dev/null || echo 0)"

    if [[ "${op_commits:-0}" -eq 0 && "${op_reviews:-0}" -eq 0 ]]; then
        AUTONOMOUS=$((AUTONOMOUS + 1))
    fi
done < <(echo "$MERGED_PRS" | python3 -c "
import json,sys
prs=json.load(sys.stdin)
for p in prs:
    print(json.dumps(p))
" 2>/dev/null)

# ── Compute rate ─────────────────────────────────────────────────────────────
if [[ "$FLEET_FILED" -eq 0 ]]; then
    RATE="0.0"
    RATE_PCT="0"
else
    RATE_PCT=$(( AUTONOMOUS * 100 / FLEET_FILED ))
    RATE="$(python3 -c "print(f'{$AUTONOMOUS/$FLEET_FILED:.3f}')" 2>/dev/null || echo "0.000")"
fi

ROW="{\"date\":\"$TODAY\",\"total_prs\":$TOTAL_PR_COUNT,\"fleet_filed\":$FLEET_FILED,\"autonomous\":$AUTONOMOUS,\"autonomous_rate\":$RATE}"

if [[ "$AS_JSON" -eq 1 ]]; then
    echo "$ROW"
else
    echo "=== Autonomous Ship Rate (CREDIBLE-047) ==="
    echo "  Window: last $TOTAL_PR_COUNT merged PRs"
    echo "  Fleet-filed: $FLEET_FILED / $TOTAL_PR_COUNT"
    echo "  Autonomous:  $AUTONOMOUS / $FLEET_FILED fleet-filed"
    echo "  Rate:        ${RATE_PCT}% ($AUTONOMOUS of $FLEET_FILED fleet-filed PRs with zero operator touch)"
    echo ""
fi

# ── Write to metrics file ────────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p "$METRICS_DIR"
    echo "$ROW" >> "$METRICS_FILE"
fi

# ── Day-over-day regression alert ────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 0 && -f "$METRICS_FILE" ]]; then
    PREV_RATE="$(tail -2 "$METRICS_FILE" | head -1 | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('autonomous_rate','0'))
except: print('0')
" 2>/dev/null || echo "0")"

    DROP="$(python3 -c "
prev=float('$PREV_RATE')
curr=float('$RATE')
drop=(prev-curr)*100
print(f'{drop:.1f}')
" 2>/dev/null || echo "0")"

    # Alert if drop > 10 percentage points
    ALERT="$(python3 -c "print('1' if float('$DROP') > 10.0 else '0')" 2>/dev/null || echo "0")"
    if [[ "$ALERT" == "1" ]]; then
        TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        EVENT="{\"ts\":\"$TS\",\"kind\":\"autonomous_ship_rate_regression\",\"prev_rate\":$PREV_RATE,\"curr_rate\":$RATE,\"drop_pp\":$DROP}"
        echo "$EVENT" >> "$AMBIENT" 2>/dev/null || true
        echo "$EVENT"
        echo "[autonomous-ship-rate] ALERT: rate dropped ${DROP}pp (prev=${PREV_RATE} curr=${RATE})" >&2
    fi
fi
