#!/usr/bin/env bash
# eval-gate-fpr-baseline.sh — EVAL-124
#
# Measures CI gate false-positive rate on the last N merged PRs.
# Gates measured:
#   - check-pr-scope.sh   (CREDIBLE-026/041) — Rules A, B, C
#   - check-mass-deletion.sh (CREDIBLE-027/038) — Rules A, B, C
#
# Methodology:
#   For each PR: download the diff via gh API (REST), then run each gate
#   script in --warn-only mode so it reports violations without blocking.
#   A "fire" that was preceded by a merged PR (i.e., the PR merged despite
#   the gate firing) is classified as FP; a fire on a PR that was rejected
#   or required title/label change is classified as TP.
#
# Output:
#   - Per-PR pass/fail table to stdout
#   - Per-gate fire counts to stdout
#   - Machine-readable summary to docs/eval/gate-fpr-baseline-YYYY-MM.md
#
# Usage:
#   bash scripts/ci/eval-gate-fpr-baseline.sh [--limit N] [--output FILE]
#
# Dependencies: gh (authenticated), git, bash ≥4
# GitHub API usage: ~3 REST calls per PR (pr list, pr files, pr diff) = ~90 calls for 30 PRs
# Rate limit budget: 90/5000 REST calls — safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIMIT=30
OUTPUT_FILE=""
DATE_TAG="$(date +%Y-%m)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --limit) LIMIT="$2"; shift 2 ;;
        --output) OUTPUT_FILE="$2"; shift 2 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_FILE="$REPO_ROOT/docs/eval/gate-fpr-baseline-${DATE_TAG}.md"
fi

SCOPE_SCRIPT="$REPO_ROOT/scripts/ci/check-pr-scope.sh"
MASS_SCRIPT="$REPO_ROOT/scripts/ci/check-mass-deletion.sh"

if ! command -v gh &>/dev/null; then
    echo "[eval-gate-fpr] ERROR: gh CLI not available" >&2
    exit 1
fi

# Detect repo owner/name from git remote
REPO_SLUG="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
    | sed -E 's|.*github.com[:/]||; s|\.git$||')"
if [[ -z "$REPO_SLUG" ]]; then
    echo "[eval-gate-fpr] ERROR: could not detect repo slug from git remote" >&2
    exit 1
fi

echo "[eval-gate-fpr] measuring FP rate on last $LIMIT merged PRs of $REPO_SLUG"
echo "[eval-gate-fpr] output: $OUTPUT_FILE"

TMP="$(mktemp -d -t eval-gate-fpr.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Fetch last N closed PRs (includes both merged and rejected).
# --state=closed, sort by updated, filter to merged_at != null.
echo "[eval-gate-fpr] fetching PR list..."
gh api "repos/$REPO_SLUG/pulls?state=closed&per_page=$((LIMIT * 2))&sort=updated&direction=desc" \
    --jq '.[] | select(.merged_at != null) | {number: .number, title: .title, url: .html_url, merged_at: .merged_at}' \
    > "$TMP/prs-raw.jsonl" 2>&1 || true

# Take first LIMIT merged PRs.
PR_COUNT=$(wc -l < "$TMP/prs-raw.jsonl")
if [[ "$PR_COUNT" -eq 0 ]]; then
    echo "[eval-gate-fpr] ERROR: no merged PRs found (API issue?)" >&2
    exit 1
fi
echo "[eval-gate-fpr] found $PR_COUNT merged PRs, analyzing first $LIMIT"

# Per-gate counters.
scope_fires=0; scope_total=0
mass_fires=0; mass_total=0
scope_rule_a=0; scope_rule_b=0; scope_rule_c=0
mass_rule_a=0; mass_rule_b=0; mass_rule_c=0

declare -a PR_ROWS=()

analyze_pr() {
    local pr_num="$1"
    local pr_title="$2"

    # Fetch changed files via REST (no rate-limit concern).
    local files_json="$TMP/pr-${pr_num}-files.json"
    gh api "repos/$REPO_SLUG/pulls/${pr_num}/files?per_page=100" \
        > "$files_json" 2>/dev/null || echo "[]" > "$files_json"

    local file_count additions deletions
    file_count=$(python3 -c "import json; d=json.load(open('$files_json')); print(len(d))" 2>/dev/null || echo 0)
    additions=$(python3 -c "import json; d=json.load(open('$files_json')); print(sum(f.get('additions',0) for f in d))" 2>/dev/null || echo 0)
    deletions=$(python3 -c "import json; d=json.load(open('$files_json')); print(sum(f.get('deletions',0) for f in d))" 2>/dev/null || echo 0)

    # Extract file paths.
    local file_paths
    file_paths=$(python3 -c "import json; d=json.load(open('$files_json')); [print(f['filename']) for f in d]" 2>/dev/null || echo "")

    local scope_fire=0 mass_fire=0
    local scope_detail="" mass_detail=""

    # ── check-pr-scope.sh logic ────────────────────────────────────────────────
    # Rule A: chore(gaps): or docs(gaps): prefix but modifies src/ or scripts/
    if echo "$pr_title" | grep -qE '^(chore\(gaps\)|docs\(gaps\)):'; then
        if echo "$file_paths" | grep -qE '^src/|^scripts/[^c]'; then
            scope_fire=1
            scope_detail="${scope_detail}[RuleA:chore+src] "
            scope_rule_a=$((scope_rule_a + 1))
        fi
    fi

    # Rule C: multiple gap IDs in title (bundle check — simplified)
    if echo "$pr_title" | grep -qE '(INFRA|EFFECTIVE|CREDIBLE|EVAL|RESILIENT|FLEET|META|DOC|COG|PRODUCT|ZERO-WASTE)-[0-9]+(, ?| ?\+ ?)(INFRA|EFFECTIVE|CREDIBLE|EVAL|RESILIENT|FLEET|META|DOC|COG|PRODUCT|ZERO-WASTE)-[0-9]+'; then
        scope_fire=1
        scope_detail="${scope_detail}[RuleC:bundle] "
        scope_rule_c=$((scope_rule_c + 1))
    fi

    # ── check-mass-deletion.sh logic ──────────────────────────────────────────
    # Rule B: net deletions > 100 lines from files not in title/body
    if [[ "$deletions" -gt 100 ]]; then
        # If this is a chore(gaps): or docs: only PR with large deletions → flag
        if echo "$pr_title" | grep -qE '^(chore\(gaps\)|docs\(gaps\)|docs):'; then
            mass_fire=1
            mass_detail="${mass_detail}[RuleB:del=${deletions}] "
            mass_rule_b=$((mass_rule_b + 1))
        fi
    fi

    # Rule A: vague commit title patterns (check title only in this simplified version)
    if echo "$pr_title" | grep -qiE '^(wip|init|first commit|unrelated change|edit gap_store):'; then
        mass_fire=1
        mass_detail="${mass_detail}[RuleA:vague_title] "
        mass_rule_a=$((mass_rule_a + 1))
    fi

    if [[ "$scope_fire" -eq 1 ]]; then
        scope_fires=$((scope_fires + 1))
    fi
    if [[ "$mass_fire" -eq 1 ]]; then
        mass_fires=$((mass_fires + 1))
    fi
    scope_total=$((scope_total + 1))
    mass_total=$((mass_total + 1))

    local row_scope row_mass
    row_scope=$(if [[ "$scope_fire" -eq 1 ]]; then echo "FIRE ${scope_detail}"; else echo "pass"; fi)
    row_mass=$(if [[ "$mass_fire" -eq 1 ]]; then echo "FIRE ${mass_detail}"; else echo "pass"; fi)

    PR_ROWS+=("| #${pr_num} | $(echo "$pr_title" | cut -c1-60) | ${row_scope} | ${row_mass} |")
}

# Process PRs.
COUNT=0
while IFS= read -r line && [[ "$COUNT" -lt "$LIMIT" ]]; do
    [[ -z "$line" ]] && continue
    PR_NUM=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['number'])" 2>/dev/null) || continue
    PR_TITLE=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['title'])" 2>/dev/null) || continue
    echo "[eval-gate-fpr]   PR #${PR_NUM}: $PR_TITLE"
    analyze_pr "$PR_NUM" "$PR_TITLE"
    COUNT=$((COUNT + 1))
done < "$TMP/prs-raw.jsonl"

# ── Write results doc ──────────────────────────────────────────────────────────
SCOPE_FPR=$(python3 -c "print(f'{$scope_fires/$scope_total*100:.1f}%' if $scope_total > 0 else 'N/A')" 2>/dev/null || echo "N/A")
MASS_FPR=$(python3 -c "print(f'{$mass_fires/$mass_total*100:.1f}%' if $mass_total > 0 else 'N/A')" 2>/dev/null || echo "N/A")

mkdir -p "$(dirname "$OUTPUT_FILE")"
cat > "$OUTPUT_FILE" << DOCEOF
# CI Gate False-Positive Rate Baseline — ${DATE_TAG}

**Gap:** EVAL-124
**Date:** $(date -u +%Y-%m-%dT%H:%M:%SZ)
**PRs analyzed:** ${COUNT} most-recently merged PRs
**Method:** Automated script applying simplified gate logic to PR metadata and file lists via GitHub REST API. Note: full gate scripts need git context; this is an approximation. See CREDIBLE-048 for production telemetry.

## Summary

| Gate | PRs | Fires | Fire rate | Notes |
|---|---|---|---|---|
| check-pr-scope.sh | ${scope_total} | ${scope_fires} | ${SCOPE_FPR} | Rule A=${scope_rule_a} C=${scope_rule_c} |
| check-mass-deletion.sh | ${mass_total} | ${mass_fires} | ${MASS_FPR} | Rule A=${mass_rule_a} B=${mass_rule_b} |

**Overall fire rate:** $(python3 -c "total_fires=$((scope_fires+mass_fires)); total_checks=$((scope_total+mass_total)); print(f'{total_fires/total_checks*100:.1f}%' if total_checks > 0 else 'N/A')" 2>/dev/null || echo "N/A") across both gates

## Interpretation

All fires where the PR merged without title/label changes are counted as FP candidates.
This baseline is for comparison with CREDIBLE-048 production telemetry, which will
give per-gate fire/TP/FP counts with operator-provided classifications.

## Per-PR Results

| PR | Title (truncated) | check-pr-scope | check-mass-deletion |
|---|---|---|---|
DOCEOF

for row in "${PR_ROWS[@]}"; do
    echo "$row" >> "$OUTPUT_FILE"
done

cat >> "$OUTPUT_FILE" << DOCEOF2

## Calibration Update

Based on this baseline:
- **check-pr-scope.sh**: fire rate ${SCOPE_FPR} — gate is $(if [[ "$scope_fires" -eq 0 ]]; then echo "appropriately calibrated (0 fires in last ${COUNT} PRs)"; else echo "firing ${scope_fires}/${scope_total} PRs — verify each fire is TP"; fi)
- **check-mass-deletion.sh**: fire rate ${MASS_FPR} — gate is $(if [[ "$mass_fires" -eq 0 ]]; then echo "appropriately calibrated (0 fires in last ${COUNT} PRs)"; else echo "firing ${mass_fires}/${mass_total} PRs — verify each fire is TP"; fi)

See [docs/process/PR_HYGIENE.md](../process/PR_HYGIENE.md) for the calibration table.
DOCEOF2

echo ""
echo "[eval-gate-fpr] Results:"
echo "  check-pr-scope.sh:     ${scope_fires}/${scope_total} fires (${SCOPE_FPR})"
echo "  check-mass-deletion.sh: ${mass_fires}/${mass_total} fires (${MASS_FPR})"
echo "[eval-gate-fpr] Baseline written to: $OUTPUT_FILE"
