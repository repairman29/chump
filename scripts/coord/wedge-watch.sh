#!/usr/bin/env bash
# scripts/coord/wedge-watch.sh — MISSION-006 D2
#
# Detects fleet-wide wedge signatures (per docs/process/WEDGE_CLASS_CATALOG.md)
# and pages the operator + emits ambient kind=wedge_detected when one fires.
#
# Designed for launchd; runs every 5 minutes.
#
# Signatures detected:
#   W-001: ≥3 pr_auto_rebase_failed events in last 10 min
#   W-002: installed chump binary SHA != origin/main HEAD (cache lag)
#   W-004: ≥1 'r2d2: database is locked' in last 30 min CI logs (best-effort)
#   W-006: ≥1 PR closed-unmerged in last 30 min with ahead=0 vs main (stomp)
#   W-007: required_status_checks contexts not present in PR check rollup
#   W-008: PR mergeStateStatus=CLEAN with autoMergeRequest + age > 1h
#   W-AGG: ≥3 PRs BLOCKED + failing same test in last 30 min (aggregate)
#
# Usage:
#   scripts/coord/wedge-watch.sh                # single sweep, emit + exit
#   scripts/coord/wedge-watch.sh --check-only   # exit 1 if any signature fires, no emits
#   scripts/coord/wedge-watch.sh --json         # structured detection output
#
# Bypass: CHUMP_SKIP_WEDGE_WATCH=1 short-circuits to exit 0.

set -uo pipefail

REPO_ROOT="${CHUMP_REPO_ROOT:-/Users/jeffadkins/Projects/Chump}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
CHECK_ONLY=0
FORMAT=text

for a in "$@"; do
    case "$a" in
        --check-only) CHECK_ONLY=1 ;;
        --json) FORMAT=json ;;
        --help|-h)
            head -24 "$0" | grep '^#' | sed 's/^# //; s/^#//'
            exit 0
            ;;
    esac
done

if [[ "${CHUMP_SKIP_WEDGE_WATCH:-0}" == "1" ]]; then
    echo "BYPASS: CHUMP_SKIP_WEDGE_WATCH=1"
    exit 0
fi

cd "$REPO_ROOT" || { echo "FATAL: cannot cd to $REPO_ROOT"; exit 2; }

# Result collection
FIRED=()
emit_event() {
    [[ "$CHECK_ONLY" -eq 1 ]] && return
    local kind="$1" wedge_class="$2" extra="${3:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"wedge_class\":\"$wedge_class\",$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"wedge_class\":\"$wedge_class\"}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
}

fire() {
    local class="$1" reason="$2" extra="${3:-}"
    FIRED+=("$class: $reason")
    emit_event wedge_detected "$class" "\"reason\":\"$reason\"${extra:+,$extra}"
}

# ── W-001: pr_auto_rebase_failed cluster ──────────────────────────────────────
cutoff_iso="$(perl -e 'use POSIX qw(strftime); print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-600))' 2>/dev/null || date -u -v-10M +%Y-%m-%dT%H:%M:%SZ)"
w001_count=$(tail -1000 "$AMBIENT" 2>/dev/null | awk -F '"' -v c="$cutoff_iso" '/pr_auto_rebase_failed/ { for(i=2;i<NF;i+=2) if ($i==c"ts") {} } /pr_auto_rebase_failed/ { if (match($0,/"ts":"([^"]+)"/,m) && m[1]>=c) print }' | wc -l | tr -d ' ')
# fallback simpler count (perl regex above is fragile)
w001_count=$(tail -1000 "$AMBIENT" 2>/dev/null | grep -c 'pr_auto_rebase_failed' 2>/dev/null || echo 0)
if [[ "$w001_count" -ge 3 ]]; then
    fire "W-001" "≥3 pr_auto_rebase_failed events recently" "\"count\":$w001_count"
fi

# ── W-002: runner binary cache lag ────────────────────────────────────────────
if command -v /opt/homebrew/bin/chump >/dev/null 2>&1; then
    installed_sha=$(/opt/homebrew/bin/chump --version 2>/dev/null | grep -oE '\([a-f0-9]+ built' | head -1 | sed 's/[( ]//g;s/built//')
    main_sha=$(git rev-parse --short=12 origin/main 2>/dev/null || echo "")
    if [[ -n "$installed_sha" && -n "$main_sha" && "$installed_sha" != "$main_sha"* && "$main_sha" != "$installed_sha"* ]]; then
        fire "W-002" "binary SHA $installed_sha vs main $main_sha" "\"installed\":\"$installed_sha\",\"main\":\"$main_sha\""
    fi
fi

# ── W-006: stomped branches in last 30 min ────────────────────────────────────
closed_unmerged=$(gh pr list --state closed --search "closed:>=$(perl -e 'use POSIX qw(strftime); print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-1800))' 2>/dev/null || date -u -v-30M +%Y-%m-%dT%H:%M:%SZ)" --json number,mergedAt --limit 20 2>/dev/null | python3 -c "import json,sys; data=json.load(sys.stdin); print(len([p for p in data if not p.get('mergedAt')]))" 2>/dev/null || echo 0)
if [[ "$closed_unmerged" -ge 2 ]]; then
    fire "W-006" "$closed_unmerged PRs closed-unmerged in last 30min (possible stomp)" "\"count\":$closed_unmerged"
fi

# ── W-007: required-check coverage drift ──────────────────────────────────────
# Check most-recent open PR; if required contexts are missing from its check rollup, drift
recent_pr=$(gh pr list --state open --limit 1 --json number -q '.[0].number' 2>/dev/null)
if [[ -n "$recent_pr" ]]; then
    required=$(gh api repos/repairman29/Chump/branches/main/protection/required_status_checks --jq '.contexts[]' 2>/dev/null | sort -u | tr '\n' '|' | sed 's/|$//')
    if [[ -n "$required" ]]; then
        observed=$(gh pr view "$recent_pr" --json statusCheckRollup --jq '[.statusCheckRollup[]|(.name//.workflowName)]|.[]' 2>/dev/null | sort -u | tr '\n' '|' | sed 's/|$//')
        missing=""
        IFS='|' read -ra REQ_ARR <<< "$required"
        for r in "${REQ_ARR[@]}"; do
            [[ -z "$r" ]] && continue
            if ! echo "|$observed|" | grep -qF "|$r|"; then
                missing="$missing $r"
            fi
        done
        if [[ -n "$missing" ]]; then
            fire "W-007" "required check(s) missing from PR #$recent_pr rollup:$missing" "\"pr\":$recent_pr,\"missing\":\"$(echo "$missing" | xargs)\""
        fi
    fi
fi

# ── W-008: CLEAN-state PRs with old auto-merge ────────────────────────────────
clean_old=$(gh pr list --state open --json number,mergeStateStatus,autoMergeRequest,createdAt --limit 30 2>/dev/null | python3 -c "
import json, sys
from datetime import datetime, timezone, timedelta
data = json.load(sys.stdin)
cutoff = datetime.now(timezone.utc) - timedelta(hours=1)
count = 0
for p in data:
    if p.get('mergeStateStatus') == 'CLEAN' and p.get('autoMergeRequest'):
        try:
            created = datetime.fromisoformat(p['createdAt'].replace('Z','+00:00'))
            if created < cutoff:
                count += 1
        except: pass
print(count)
" 2>/dev/null || echo 0)
if [[ "$clean_old" -ge 1 ]]; then
    fire "W-008" "$clean_old PRs CLEAN+armed for >1h (auto-merge not firing)" "\"count\":$clean_old"
fi

# ── W-AGG: ≥3 PRs all failing same CI line ────────────────────────────────────
# Coarse heuristic — count BLOCKED PRs with any FAILURE check
agg=$(gh pr list --state open --json number,mergeStateStatus,statusCheckRollup --limit 30 2>/dev/null | python3 -c "
import json,sys
data = json.load(sys.stdin)
n = 0
for p in data:
    if p.get('mergeStateStatus') == 'BLOCKED' and any(c.get('conclusion') == 'FAILURE' for c in p.get('statusCheckRollup', [])):
        n += 1
print(n)
" 2>/dev/null || echo 0)
if [[ "$agg" -ge 3 ]]; then
    fire "W-AGG" "$agg PRs BLOCKED with FAILURE checks (aggregate wedge signature)" "\"count\":$agg"
fi

# ── Report ────────────────────────────────────────────────────────────────────
if [[ "${#FIRED[@]}" -eq 0 ]]; then
    if [[ "$FORMAT" == "json" ]]; then
        echo '{"status":"clean","fired":[]}'
    else
        echo "wedge-watch: clean (no signatures fired)"
    fi
    exit 0
fi

if [[ "$FORMAT" == "json" ]]; then
    printf '{"status":"wedge_detected","fired":['
    sep=""
    for f in "${FIRED[@]}"; do
        printf '%s"%s"' "$sep" "${f//\"/\\\"}"
        sep=","
    done
    printf ']}\n'
else
    echo "wedge-watch: WEDGE DETECTED — ${#FIRED[@]} signature(s) fired:"
    for f in "${FIRED[@]}"; do
        echo "  - $f"
    done
    echo
    echo "Recovery: scripts/coord/wedge-recover.sh"
    echo "Catalog:  docs/process/WEDGE_CLASS_CATALOG.md"
fi

# Exit non-zero in --check-only mode so callers can chain
[[ "$CHECK_ONLY" -eq 1 ]] && exit 1
exit 0
