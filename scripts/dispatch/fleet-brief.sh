#!/usr/bin/env bash
# fleet-brief.sh — INFRA-721
#
# 60-second operator briefing. Computes:
#   - 24h ship count + rate trend
#   - pillar mix from shipped PR titles (RESILIENT/EFFECTIVE/CREDIBLE/ZERO-WASTE/MISSION)
#   - open PR stalls (BLOCKED > 4h)
#   - auto-fixed CI events (lint/flake reruns) — count of "saved" operator interventions
#   - manual rescue events (kind=manual_rescue or stuck-PR-filer triggers)
#   - suggested next operator action
#
# Output: 30 lines max, plain text, scannable.
#
# Designed to be called by SessionStart hook (FLEET-019/INFRA-721) so operator
# sees state without having to ask. Stdout-only; non-fatal on missing data.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"

now_epoch=$(date +%s)
day_ago=$((now_epoch - 86400))
four_h_ago=$((now_epoch - 14400))
since_iso=$(date -u -r $day_ago +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$day_ago" +%Y-%m-%dT%H:%M:%SZ)

# ── 24h ship metrics (from gh) ───────────────────────────────────────────
ships_24h=$(gh pr list --state merged --search "merged:>=$since_iso" --json number 2>/dev/null | jq 'length' 2>/dev/null || echo "?")
rate_per_hr=$(awk "BEGIN{printf \"%.1f\", ($ships_24h)/24}" 2>/dev/null)

# Pillar mix: PR titles don't carry pillar prefix consistently, so look up
# each gap_id in state.db and match its title's pillar tag. Fall back to
# domain-bucket if no pillar tag.
p_resilient=0; p_effective=0; p_credible=0; p_zerowaste=0; p_mission=0; p_other=0
d_infra=0; d_fleet=0; d_doc=0; d_credible=0; d_cog=0; d_product=0; d_other=0
while IFS= read -r pr_title; do
    # Extract gap-id (e.g. "INFRA-669" from "INFRA-669: pr-triage-bot ...")
    gap_id=$(echo "$pr_title" | grep -oE '^[A-Z]+-[0-9]+' | head -1)
    domain=$(echo "$gap_id" | cut -d- -f1)
    case "$domain" in
        INFRA) d_infra=$((d_infra + 1)) ;;
        FLEET) d_fleet=$((d_fleet + 1)) ;;
        DOC) d_doc=$((d_doc + 1)) ;;
        CREDIBLE) d_credible=$((d_credible + 1)) ;;
        COG) d_cog=$((d_cog + 1)) ;;
        PRODUCT) d_product=$((d_product + 1)) ;;
        *) d_other=$((d_other + 1)) ;;
    esac
    # Pillar from gap state.db title
    if [ -n "$gap_id" ]; then
        gap_title=$(chump gap show "$gap_id" 2>/dev/null | awk '/^  title:/{sub(/^  title: /,""); print; exit}')
        case "$gap_title" in
            *"RESILIENT:"*)    p_resilient=$((p_resilient + 1)) ;;
            *"EFFECTIVE:"*)    p_effective=$((p_effective + 1)) ;;
            *"CREDIBLE:"*)     p_credible=$((p_credible + 1)) ;;
            *"ZERO-WASTE:"*)   p_zerowaste=$((p_zerowaste + 1)) ;;
            *"MISSION:"*)      p_mission=$((p_mission + 1)) ;;
            *)                 p_other=$((p_other + 1)) ;;
        esac
    else
        p_other=$((p_other + 1))
    fi
done < <(gh pr list --state merged --search "merged:>=$since_iso" --json title -q '.[].title' 2>/dev/null)

# ── Open PR stalls (BLOCKED > 4h) ────────────────────────────────────────
stalls_4h=()
while IFS=$'\t' read -r num created msstate; do
    [ "$msstate" != "BLOCKED" ] && continue
    [ -z "$created" ] && continue
    created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created" +%s 2>/dev/null || echo 0)
    [ "$created_epoch" = "0" ] && continue
    if [ "$created_epoch" -lt "$four_h_ago" ]; then
        stalls_4h+=("#$num")
    fi
done < <(gh pr list --state open --json number,createdAt,mergeStateStatus -q '.[] | [.number, .createdAt, .mergeStateStatus] | @tsv' 2>/dev/null)

# ── Auto-fixed counts from ambient (last 24h) ────────────────────────────
auto_lint_fixes=0
auto_flake_reruns=0
manual_rescues=0
if [ -f "$AMBIENT_LOG" ]; then
    auto_lint_fixes=$(awk -v cutoff="$since_iso" '$0 ~ /"kind":"auto_fix_lint"/ && $0 ~ "\"ts\":\""' "$AMBIENT_LOG" 2>/dev/null | wc -l | tr -d ' ')
    auto_flake_reruns=$(awk -v cutoff="$since_iso" '$0 ~ /"kind":"flake_rerun"/' "$AMBIENT_LOG" 2>/dev/null | wc -l | tr -d ' ')
    manual_rescues=$(awk -v cutoff="$since_iso" '$0 ~ /"kind":"manual_rescue"/' "$AMBIENT_LOG" 2>/dev/null | wc -l | tr -d ' ')
fi

# ── Suggest next action ──────────────────────────────────────────────────
suggestions=()
total_pillar=$((p_resilient + p_effective + p_credible + p_zerowaste + p_mission))
if [ "$total_pillar" -gt "5" ]; then
    # check if any of the user-mission pillars (EFFECTIVE/CREDIBLE/MISSION) is < 10%
    eff_pct=$(( (p_effective * 100) / total_pillar ))
    cred_pct=$(( (p_credible * 100) / total_pillar ))
    miss_pct=$(( (p_mission * 100) / total_pillar ))
    if [ "$eff_pct" -lt "10" ]; then
        suggestions+=("pillar imbalance: EFFECTIVE only ${eff_pct}% of last 24h ships — refill queue")
    elif [ "$cred_pct" -lt "10" ]; then
        suggestions+=("pillar imbalance: CREDIBLE only ${cred_pct}% of last 24h ships — refill queue")
    elif [ "$miss_pct" -lt "5" ] && [ "$total_pillar" -gt "10" ]; then
        suggestions+=("pillar imbalance: MISSION only ${miss_pct}% — file user-facing gap")
    fi
fi
if [ "${#stalls_4h[@]}" -gt "0" ]; then
    suggestions+=("triage stalls: ${stalls_4h[*]}")
fi

# ── Render ───────────────────────────────────────────────────────────────
echo "═══ Fleet brief (last 24h) ═══"
echo "Ships: $ships_24h (≈${rate_per_hr}/hr)"
pmix=""
[ "$p_resilient" -gt 0 ] && pmix="${pmix} RESILIENT=$p_resilient"
[ "$p_effective" -gt 0 ] && pmix="${pmix} EFFECTIVE=$p_effective"
[ "$p_credible" -gt 0 ] && pmix="${pmix} CREDIBLE=$p_credible"
[ "$p_zerowaste" -gt 0 ] && pmix="${pmix} ZERO-WASTE=$p_zerowaste"
[ "$p_mission" -gt 0 ] && pmix="${pmix} MISSION=$p_mission"
[ "$p_other" -gt 0 ] && pmix="${pmix} OTHER=$p_other"
echo "Pillars:${pmix}"
dmix=""
[ "$d_infra" -gt 0 ] && dmix="${dmix} INFRA=$d_infra"
[ "$d_fleet" -gt 0 ] && dmix="${dmix} FLEET=$d_fleet"
[ "$d_doc" -gt 0 ] && dmix="${dmix} DOC=$d_doc"
[ "$d_credible" -gt 0 ] && dmix="${dmix} CREDIBLE=$d_credible"
[ "$d_cog" -gt 0 ] && dmix="${dmix} COG=$d_cog"
[ "$d_product" -gt 0 ] && dmix="${dmix} PRODUCT=$d_product"
[ "$d_other" -gt 0 ] && dmix="${dmix} OTHER=$d_other"
echo "Domains:${dmix}"
stalls_str=""
[ "${#stalls_4h[@]}" -gt 0 ] && stalls_str=" (${stalls_4h[*]})"
echo "Stalls > 4h: ${#stalls_4h[@]}${stalls_str}"
echo "Auto-fixed: lint=$auto_lint_fixes flake-rerun=$auto_flake_reruns"
echo "Manual rescues: $manual_rescues"
if [ "${#suggestions[@]}" -gt "0" ]; then
    echo ""
    echo "Suggested actions:"
    for s in "${suggestions[@]}"; do
        echo "  • $s"
    done
fi
