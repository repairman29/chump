#!/usr/bin/env bash
# ci-fleet-health-sweep.sh — CREDIBLE-220
#
# Nothing was watching default-branch CI health on the fleet's OTHER repos
# (ai-gm-service, jarvis-rog-ed, etc.) — chump's own ci-health-weekly.sh only
# ever reads `chump ci-summary`, which is chump-internal. Two repos sat red
# for ~6 months (ai-gm-service since 2026-01-21, jarvis-rog-ed since
# 2026-01-31) and were only discovered incidentally on 2026-08-07.
#
# This sweep reads the fleet repo list from docs/arsenal/GLOBAL_ARSENAL.json
# (the Harvester's catalog — already the fleet's source of truth for "which
# repos exist"), checks the latest default-branch Actions run per repo, and
# tracks how long each repo has been continuously red in a local state file.
# A repo red for >= N days (default 3) gets ONE gap filed (deduped by repo —
# state file remembers we already filed, so a standing red condition does
# not refile every cycle, matching the posse-sweep dedupe idiom referenced
# in EFFECTIVE-389/398).
#
# Filing target: `chump gap reserve --external-repo owner/repo`. That is
# chump's native equivalent of the holler->chump bridge's external_repo
# tagging convention (see EFFECTIVE-398) — the actual shared/playtest/
# holler.mjs bridge lives outside this repo/machine and isn't reachable
# from a chump worktree, so this sweep files directly through the gap
# store using the same tag shape the bridge would produce.
#
# Cheap red-cause classification (AC #3): a repo whose latest run failed is
# classified via known error-signature grep over the failed run's log
# rather than a full log read — "missing_script" (npm ERR! missing script),
# "missing_lockfile" (setup-node cache: needs a lockfile), or
# "unclassified" (assume real test failure — the pricier fix class).
#
# Usage:
#   ./scripts/coord/ci-fleet-health-sweep.sh [--dry-run] [--days N] [--json]
#
# Env overrides:
#   CHUMP_CI_FLEET_SWEEP_DAYS       — red-streak threshold in days (default 3)
#   CHUMP_CI_FLEET_SWEEP_OWNER      — github org/user to scope the sweep (default repairman29)
#   CHUMP_CI_FLEET_SWEEP_STATE      — state file path (default $REPO_ROOT/.chump/ci-fleet-health-state.json)
#   CHUMP_CI_FLEET_SWEEP_ARSENAL    — path to GLOBAL_ARSENAL.json (default docs/arsenal/GLOBAL_ARSENAL.json)
#   CHUMP_AMBIENT_LOG               — path to ambient.jsonl (default .chump-locks/ambient.jsonl)
#   CHUMP_CI_FLEET_SWEEP_DISABLE=1  — noop
#
# Emits to ambient.jsonl: kind=ci_fleet_health_red (one per newly-filed repo)
#
# Install via launchd (daily):
#   cp launchd/com.chump.ci-fleet-health-sweep.plist ~/Library/LaunchAgents/
#   launchctl load ~/Library/LaunchAgents/com.chump.ci-fleet-health-sweep.plist

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
_common="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$_common" && "$_common" != ".git" ]]; then
    REPO_ROOT="$(cd "$REPO_ROOT" && git rev-parse --path-format=absolute --git-common-dir | xargs dirname 2>/dev/null || echo "$REPO_ROOT")"
fi

DAYS="${CHUMP_CI_FLEET_SWEEP_DAYS:-3}"
OWNER="${CHUMP_CI_FLEET_SWEEP_OWNER:-repairman29}"
STATE_FILE="${CHUMP_CI_FLEET_SWEEP_STATE:-$REPO_ROOT/.chump/ci-fleet-health-state.json}"
ARSENAL="${CHUMP_CI_FLEET_SWEEP_ARSENAL:-$REPO_ROOT/docs/arsenal/GLOBAL_ARSENAL.json}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

DRY_RUN=0
JSON_OUT=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --json) JSON_OUT=1 ;;
        --days=*) DAYS="${arg#*=}" ;;
        --days) shift ;;
    esac
done

if [[ "${CHUMP_CI_FLEET_SWEEP_DISABLE:-0}" == "1" ]]; then
    echo "[ci-fleet-health-sweep] CHUMP_CI_FLEET_SWEEP_DISABLE=1 — noop"
    exit 0
fi

if [[ ! -f "$ARSENAL" ]]; then
    echo "[ci-fleet-health-sweep] arsenal catalog missing at $ARSENAL — nothing to sweep" >&2
    exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "[ci-fleet-health-sweep] gh CLI not on PATH — cannot check Actions state" >&2
    exit 1
fi

mkdir -p "$(dirname "$STATE_FILE")"
[[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_emit() {
    local kind="$1"; shift
    local extra="${1:-}"
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s"%s}\n' "$(_ts)" "$kind" "${extra:+,$extra}" \
        >> "$AMBIENT" 2>/dev/null || true
}

# Classify a red repo's cheapest-fix cause via known error signatures in the
# latest failed run's log. Falls back to "unclassified" (assume real test
# failure) if no known signature matches.
_classify_red() {
    local owner_repo="$1" run_id="$2"
    local log
    log="$(gh run view "$run_id" --repo "$owner_repo" --log-failed 2>/dev/null || true)"
    if grep -qi 'missing script' <<<"$log"; then
        echo "missing_script"
    elif grep -qiE 'lockfile|lock file' <<<"$log" && grep -qi 'setup-node\|npm cache' <<<"$log"; then
        echo "missing_lockfile"
    elif grep -qiE "Dependencies lock file is not found" <<<"$log"; then
        echo "missing_lockfile"
    else
        echo "unclassified"
    fi
}

# ── Build repo list from the arsenal catalog ─────────────────────────────────
repos_json="$(python3 - "$ARSENAL" "$OWNER" <<'PYEOF'
import json, sys
path, owner = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = json.load(f)
out = []
for name, r in d.get("repos_by_name", {}).items():
    if r.get("archived"):
        continue
    if r.get("fork"):
        continue
    url = r.get("url", "")
    if f"github.com/{owner}/" not in url:
        continue
    out.append(name)
print(json.dumps(sorted(out)))
PYEOF
)"

mapfile -t REPOS < <(python3 -c "import json,sys; print('\n'.join(json.loads(sys.argv[1])))" "$repos_json")
echo "[ci-fleet-health-sweep] scanning ${#REPOS[@]} non-archived $OWNER repos (threshold=${DAYS}d)"

now_epoch="$(date -u +%s)"
newly_filed=0
still_red=0
recovered=0

for repo in "${REPOS[@]}"; do
    owner_repo="$OWNER/$repo"
    default_branch="$(gh api "repos/$owner_repo" --jq .default_branch 2>/dev/null || echo "")"
    if [[ -z "$default_branch" ]]; then
        continue  # repo gone / no API access — skip rather than misreport
    fi
    # Default-branch runs only (not PR branches) — `gh run list` without
    # --branch returns the latest run across ALL branches/events.
    run_json="$(gh run list --repo "$owner_repo" --branch "$default_branch" --event push --limit 1 \
        --json conclusion,createdAt,databaseId 2>/dev/null || echo '[]')"
    conclusion="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print((d[0].get('conclusion') or '') if d else '')" "$run_json" 2>/dev/null || echo "")"
    run_id="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d[0].get('databaseId','') if d else '')" "$run_json" 2>/dev/null || echo "")"

    if [[ -z "$run_json" || "$run_json" == "[]" ]]; then
        continue  # no default-branch push run history — nothing to watch yet
    fi

    prev_first_red="$(python3 -c "
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    d={}
print(d.get(sys.argv[2],{}).get('first_red_at',''))
" "$STATE_FILE" "$repo" 2>/dev/null || echo "")"
    already_filed="$(python3 -c "
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    d={}
print('1' if d.get(sys.argv[2],{}).get('filed') else '0')
" "$STATE_FILE" "$repo" 2>/dev/null || echo "0")"

    if [[ "$conclusion" == "failure" ]]; then
        first_red_at="$prev_first_red"
        if [[ -z "$first_red_at" ]]; then
            first_red_at="$(_ts)"
        fi
        first_red_epoch="$(date -u -d "$first_red_at" +%s 2>/dev/null || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$first_red_at" +%s 2>/dev/null || echo "$now_epoch")"
        red_days=$(( (now_epoch - first_red_epoch) / 86400 ))
        still_red=$((still_red+1))

        cause="unclassified"
        if [[ "$red_days" -ge "$DAYS" && "$already_filed" != "1" ]]; then
            [[ -n "$run_id" ]] && cause="$(_classify_red "$owner_repo" "$run_id")"
            title="CI red ${red_days}d on ${owner_repo} default branch (${cause})"
            echo "[ci-fleet-health-sweep] FILING: $title"
            if [[ "$DRY_RUN" -eq 0 ]]; then
                if [[ "$cause" == "missing_script" || "$cause" == "missing_lockfile" ]]; then
                    domain="INFRA"  # cheap workflow-config fix class
                else
                    domain="CREDIBLE"  # unclassified — treat as needing investigation
                fi
                chump gap reserve --domain "$domain" \
                    --title "$title" \
                    --external-repo "$owner_repo" \
                    --priority P2 --effort xs \
                    2>&1 | tail -5 || echo "[ci-fleet-health-sweep] WARN: gap reserve failed for $owner_repo" >&2
                # scanner-anchor: "kind":"ci_fleet_health_red"
                _emit "ci_fleet_health_red" "\"repo\":\"$owner_repo\",\"red_days\":$red_days,\"cause\":\"$cause\""
            fi
            newly_filed=$((newly_filed+1))
            already_filed="1"
        fi

        python3 -c "
import json,sys
path=sys.argv[1]; repo=sys.argv[2]; first_red=sys.argv[3]; filed=sys.argv[4]=='1'; cause=sys.argv[5]
try:
    d=json.load(open(path))
except Exception:
    d={}
d[repo]={'first_red_at': first_red, 'filed': filed, 'last_cause': cause, 'last_checked': sys.argv[6]}
json.dump(d, open(path,'w'), indent=2, sort_keys=True)
" "$STATE_FILE" "$repo" "$first_red_at" "$already_filed" "$cause" "$(_ts)"
    else
        if [[ -n "$prev_first_red" ]]; then
            recovered=$((recovered+1))
        fi
        python3 -c "
import json,sys
path=sys.argv[1]; repo=sys.argv[2]
try:
    d=json.load(open(path))
except Exception:
    d={}
d.pop(repo, None)
json.dump(d, open(path,'w'), indent=2, sort_keys=True)
" "$STATE_FILE" "$repo"
    fi
done

echo "[ci-fleet-health-sweep] done: still_red=$still_red newly_filed=$newly_filed recovered=$recovered"
if [[ "$JSON_OUT" -eq 1 ]]; then
    printf '{"still_red":%d,"newly_filed":%d,"recovered":%d}\n' "$still_red" "$newly_filed" "$recovered"
fi
