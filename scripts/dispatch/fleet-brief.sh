#!/usr/bin/env bash
# fleet-brief.sh — INFRA-721
#
# 60-second operator briefing. Computes:
#   - 24h + 1h ship count + rate trend (INFRA-2013: leading indicator)
#   - pillar mix from shipped PR titles (RESILIENT/EFFECTIVE/CREDIBLE/ZERO-WASTE/MISSION)
#   - open PR stalls (BLOCKED > 4h)
#   - STALLED alert when ships_1h==0 and BLOCKED>=2 (INFRA-2013)
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
# shellcheck disable=SC2034  # day_ago: used by sub-scripts that source fleet-brief.sh
day_ago=$((now_epoch - 86400))
four_h_ago=$((now_epoch - 14400))
# shellcheck disable=SC2034  # one_h_ago: reserved for future 1h threshold callers
one_h_ago=$((now_epoch - 3600))

# INFRA-1148: git log replaces gh pr list (GraphQL) for all ship counts and
# pillar mix. Zero API calls — always reliable, always fast (<50ms).
# Commit subjects follow `type(DOMAIN-NNN): PILLAR — ...` convention.
_git_log_24h() { git -C "$MAIN_REPO" log --format="%s" --after="24 hours ago" origin/main 2>/dev/null || true; }
_git_log_6h()  { git -C "$MAIN_REPO" log --format="%s" --after="6 hours ago"  origin/main 2>/dev/null || true; }
# INFRA-2013: 1h window for leading-indicator stall detection
_git_log_1h()  { git -C "$MAIN_REPO" log --format="%s" --after="1 hour ago"   origin/main 2>/dev/null || true; }

_subjects_24h="$(_git_log_24h)"
_subjects_6h="$(_git_log_6h)"
_subjects_1h="$(_git_log_1h)"

ships_24h=$(echo "$_subjects_24h" | grep -c . 2>/dev/null || echo 0)
ships_6h=$(echo "$_subjects_6h"  | grep -c . 2>/dev/null || echo 0)
ships_1h=$(echo "$_subjects_1h"  | grep -c . 2>/dev/null || echo 0)
[[ -z "$_subjects_24h" ]] && ships_24h=0
[[ -z "$_subjects_6h"  ]] && ships_6h=0
[[ -z "$_subjects_1h"  ]] && ships_1h=0
rate_per_hr=$(awk "BEGIN{printf \"%.1f\", ($ships_24h)/24}" 2>/dev/null)

# ── Classify pillar + domain from commit subjects (24h) ──────────────────
# Subjects: fix(INFRA-1141): RESILIENT — ...,  feat(DOC-048): CREDIBLE — ...
# Pillar tag appears after ): in the subject; domain is from gap prefix.
p_resilient=0; p_effective=0; p_credible=0; p_zerowaste=0; p_mission=0; p_other=0
d_infra=0; d_fleet=0; d_doc=0; d_credible=0; d_cog=0; d_product=0; d_other=0
while IFS= read -r subj; do
    [[ -z "$subj" ]] && continue
    # Extract domain from gap id inside parens: fix(INFRA-1141) → INFRA
    domain=$(echo "$subj" | grep -oE '\(([A-Z]+-[0-9]+)\)' | head -1 | tr -d '()')
    domain="${domain%%-*}"
    case "$domain" in
        INFRA)    d_infra=$((d_infra + 1)) ;;
        FLEET)    d_fleet=$((d_fleet + 1)) ;;
        DOC)      d_doc=$((d_doc + 1)) ;;
        CREDIBLE) d_credible=$((d_credible + 1)) ;;
        COG)      d_cog=$((d_cog + 1)) ;;
        PRODUCT)  d_product=$((d_product + 1)) ;;
        *)        d_other=$((d_other + 1)) ;;
    esac
    case "$subj" in
        *"RESILIENT"*)  p_resilient=$((p_resilient + 1)) ;;
        *"EFFECTIVE"*)  p_effective=$((p_effective + 1)) ;;
        *"CREDIBLE"*)   p_credible=$((p_credible + 1)) ;;
        *"ZERO-WASTE"*) p_zerowaste=$((p_zerowaste + 1)) ;;
        *"MISSION"*)    p_mission=$((p_mission + 1)) ;;
        *)              p_other=$((p_other + 1)) ;;
    esac
done <<< "$_subjects_24h"

# ── 6h pillar breakdown (for the 'Shipped last 6h' table) ────────────────
s6_resilient=0; s6_effective=0; s6_credible=0; s6_zerowaste=0; s6_mission=0; s6_other=0
while IFS= read -r subj; do
    [[ -z "$subj" ]] && continue
    case "$subj" in
        *"RESILIENT"*)  s6_resilient=$((s6_resilient + 1)) ;;
        *"EFFECTIVE"*)  s6_effective=$((s6_effective + 1)) ;;
        *"CREDIBLE"*)   s6_credible=$((s6_credible + 1)) ;;
        *"ZERO-WASTE"*) s6_zerowaste=$((s6_zerowaste + 1)) ;;
        *"MISSION"*)    s6_mission=$((s6_mission + 1)) ;;
        *)              s6_other=$((s6_other + 1)) ;;
    esac
done <<< "$_subjects_6h"

# ── Overlap clusters: top-level dirs touched by ≥3 ships (last 6h) ───────
_overlap_clusters=""
_overlap_raw=$(git -C "$MAIN_REPO" log --name-only --format="" --after="6 hours ago" origin/main 2>/dev/null \
    | sed 's|/.*||' | grep -v '^$' | sort | uniq -c | sort -rn \
    | awk '$1>=3 {print $1, $2}' || true)
[[ -n "$_overlap_raw" ]] && _overlap_clusters="$_overlap_raw"

# ── Open PR stalls (BLOCKED > 4h) ────────────────────────────────────────
stalls_4h=()
blocked_count=0
while IFS=$'\t' read -r num created msstate; do
    [ "$msstate" != "BLOCKED" ] && continue
    [ -z "$created" ] && continue
    blocked_count=$((blocked_count + 1))
    created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created" +%s 2>/dev/null || echo 0)
    [ "$created_epoch" = "0" ] && continue
    if [ "$created_epoch" -lt "$four_h_ago" ]; then
        stalls_4h+=("#$num")
    fi
done < <(gh pr list --state open --json number,createdAt,mergeStateStatus -q '.[] | [.number, .createdAt, .mergeStateStatus] | @tsv' 2>/dev/null)

# ── INFRA-2013: Fleet stall detection (leading indicator) ────────────────
# Condition: ships_1h == 0 AND open BLOCKED PRs >= 2
# Emit kind=fleet_stalled to ambient so watchers can page/escalate.
_fleet_stalled=0
if [[ "$ships_1h" -eq 0 && "$blocked_count" -ge 2 ]]; then
    _fleet_stalled=1
    _stall_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"fleet_stalled","ships_1h":0,"blocked_open":%d,"source":"fleet-brief.sh"}\n' \
        "$_stall_ts" "$blocked_count" >> "$AMBIENT_LOG" 2>/dev/null || true
fi

# ── INFRA-2040: Silent fleet death detection ──────────────────────────────
# Condition: last merge into origin/main > SILENT_DEATH_MERGE_HOURS (default 12h)
# AND at least one com/dev.chump.* launchd daemon has exit code != 0.
# This catches the "brief says healthy but floor is dead" class from 2026-05-26.
_SILENT_DEATH_MERGE_HOURS="${SILENT_DEATH_MERGE_HOURS:-12}"
_silent_fleet_dead=0
_sfd_merge_age_h=0
_sfd_dead_count=0
_sfd_dead_labels=""

_last_merge_ts="$(git -C "$MAIN_REPO" log origin/main -1 --format="%ct" 2>/dev/null || echo 0)"
if [[ "$_last_merge_ts" -gt 0 ]]; then
    _sfd_merge_age_h=$(( (now_epoch - _last_merge_ts) / 3600 ))
fi
_merge_stale=0
[[ "$_sfd_merge_age_h" -ge "$_SILENT_DEATH_MERGE_HOURS" ]] && _merge_stale=1

if command -v launchctl &>/dev/null && [[ "$(uname)" == "Darwin" ]]; then
    _uid="$(id -u)"
    _dead_labels_arr=()
    while IFS= read -r _lbl; do
        [[ -z "$_lbl" ]] && continue
        _ec="$(launchctl print "gui/$_uid/$_lbl" 2>/dev/null \
            || launchctl print "system/$_lbl" 2>/dev/null \
            || true)"
        _exit_code="$(echo "$_ec" | grep -E 'last exit code\s*=' | grep -oE '[-]?[0-9]+' | head -1 || true)"
        [[ -z "$_exit_code" ]] && continue
        [[ "$_exit_code" != "0" ]] && _dead_labels_arr+=("${_lbl}(exit=${_exit_code})")
    done < <(launchctl list 2>/dev/null | awk '{print $3}' | grep -E '^(com|dev)\.chump\.' || true)

    _sfd_dead_count="${#_dead_labels_arr[@]}"
    _sfd_dead_labels="${_dead_labels_arr[*]:-}"

    if [[ "$_merge_stale" -eq 1 && "$_sfd_dead_count" -gt 0 ]]; then
        _silent_fleet_dead=1
        printf '{"ts":"%s","kind":"silent_fleet_death","merge_age_h":%d,"dead_daemon_count":%d,"dead_daemons":"%s","source":"fleet-brief.sh"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_sfd_merge_age_h" "$_sfd_dead_count" "$_sfd_dead_labels" \
            >> "$AMBIENT_LOG" 2>/dev/null || true
    fi
fi

# ── Auto-fixed counts from ambient (last 24h) ────────────────────────────
auto_lint_fixes=0
auto_flake_reruns=0
manual_rescues=0
# since_iso: ISO timestamp 24h ago for awk cutoff filter.
since_iso="$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '1970-01-01T00:00:00Z')"
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
# INFRA-2013: show 1h ships as leading indicator alongside 24h rolling average
echo "Ships: $ships_24h (≈${rate_per_hr}/hr) | last 6h: $ships_6h | last 1h: $ships_1h"
# INFRA-2040: silent-fleet-death banner — takes priority over STALLED (more severe)
if [[ "$_silent_fleet_dead" -eq 1 ]]; then
    if [[ -t 1 ]]; then
        printf '\033[1;31m*** ALERT: SILENT-FLEET-DEATH — last merge %dh ago + %d daemon(s) dead: %s — run: chump fleet doctor ***\033[0m\n' \
            "$_sfd_merge_age_h" "$_sfd_dead_count" "$_sfd_dead_labels"
    else
        printf '*** ALERT: SILENT-FLEET-DEATH — last merge %dh ago + %d daemon(s) dead: %s — run: chump fleet doctor ***\n' \
            "$_sfd_merge_age_h" "$_sfd_dead_count" "$_sfd_dead_labels"
    fi
fi
# INFRA-2013: prominent STALLED banner when condition met
if [[ "$_fleet_stalled" -eq 1 ]]; then
    # Use ANSI red if terminal supports it; fallback to plain text
    if [[ -t 1 ]]; then
        printf '\033[1;31m*** STALLED: 0 merges in last 1h with %d BLOCKED PRs — investigate now ***\033[0m\n' "$blocked_count"
    else
        echo "*** STALLED: 0 merges in last 1h with ${blocked_count} BLOCKED PRs — investigate now ***"
    fi
fi
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

# ── Shipped last 6h grouped by pillar ────────────────────────────────────
if [[ "$ships_6h" -gt 0 ]]; then
    echo ""
    echo "Shipped last 6h ($ships_6h total):"
    [ "$s6_resilient" -gt 0 ] && printf "  %-12s %d\n" "RESILIENT"  "$s6_resilient"
    [ "$s6_effective" -gt 0 ] && printf "  %-12s %d\n" "EFFECTIVE"  "$s6_effective"
    [ "$s6_credible"  -gt 0 ] && printf "  %-12s %d\n" "CREDIBLE"   "$s6_credible"
    [ "$s6_zerowaste" -gt 0 ] && printf "  %-12s %d\n" "ZERO-WASTE" "$s6_zerowaste"
    [ "$s6_mission"   -gt 0 ] && printf "  %-12s %d\n" "MISSION"    "$s6_mission"
    [ "$s6_other"     -gt 0 ] && printf "  %-12s %d\n" "OTHER"      "$s6_other"
fi

# ── Overlap clusters ──────────────────────────────────────────────────────
if [[ -n "$_overlap_clusters" ]]; then
    echo ""
    echo "Overlap clusters (≥3 ships in 6h, same top-level dir):"
    while IFS= read -r cl; do
        echo "  $cl"
    done <<< "$_overlap_clusters"
fi
# CREDIBLE-025: per-model ship breakdown (from ship_grade events).
_model_rate_script="$REPO_ROOT/scripts/dispatch/model-ship-rate.sh"
if [[ -x "$_model_rate_script" ]]; then
    _msr_out="$(bash "$_model_rate_script" --window 24h 2>/dev/null || true)"
    if [[ -n "$_msr_out" && "$_msr_out" != *"no ship_grade events"* ]]; then
        echo ""
        echo "$_msr_out"
    fi
fi
if [ "${#suggestions[@]}" -gt "0" ]; then
    echo ""
    echo "Suggested actions:"
    for s in "${suggestions[@]}"; do
        echo "  • $s"
    done
fi

# CREDIBLE-034: per-pillar pickable gap table.
# Shows how many P1 xs|s|m gaps are available per pillar — zero means the
# pillar needs refilling before the next pick (CLAUDE.md §Mission Driver).
_chump="${CHUMP_BIN:-$(command -v chump 2>/dev/null || echo "$REPO_ROOT/target/debug/chump")}"
if [[ -x "$_chump" ]]; then
    _open_gaps="$("$_chump" gap list --status open 2>/dev/null || true)"
    # INFRA-1355: in a fresh worktree state.db is empty and the first call
    # auto-imports + exits with a "re-run to list" message (INFRA-821). The
    # brief then saw an empty body and reported Pillars=0/0/0/0 even when
    # 17+ gaps were actually pickable. Re-run when we detect the import notice.
    if echo "$_open_gaps" | grep -q "imported.*gap.*re-run to list"; then
        _open_gaps="$("$_chump" gap list --status open 2>/dev/null || true)"
    fi
    _count_pillar() {
        local tag="$1"
        echo "$_open_gaps" \
            | grep -E "\[open\].*${tag}" \
            | grep -cE "P1/(xs|s|m)\)" \
            || true
    }
    _fmt_count() {
        local n="$1"
        if [[ "$n" -eq 0 ]]; then echo "0 (!)"; else echo "$n"; fi
    }
    _p_eff=$(_count_pillar "EFFECTIVE:")
    _p_cred=$(_count_pillar "CREDIBLE:")
    _p_res=$(_count_pillar "RESILIENT:")
    _p_zw=$(_count_pillar "ZERO-WASTE:")
    echo ""
    echo "Pillar pickable (P1 xs|s|m):"
    printf "  %-12s %s\n" "EFFECTIVE"  "$(_fmt_count "$_p_eff")"
    printf "  %-12s %s\n" "CREDIBLE"   "$(_fmt_count "$_p_cred")"
    printf "  %-12s %s\n" "RESILIENT"  "$(_fmt_count "$_p_res")"
    printf "  %-12s %s\n" "ZERO-WASTE" "$(_fmt_count "$_p_zw")"
    unset _open_gaps _p_eff _p_cred _p_res _p_zw
fi
unset _chump
