#!/usr/bin/env bash
# scripts/coord/blame-bot.sh — INFRA-1989 (THE FLOOR Phase 1 finisher)
#
# When CI goes red on main (or a cluster fires per INFRA-1987), this tool
# automates the green-to-red attribution: finds the last GREEN CI run,
# diffs the prod paths since then, and surfaces the suspect commit(s).
#
# Converts the 50-min `bash -x` archaeology I did during the 5-PR pile-up
# RCA (INFRA-1986) into <30 sec of "here's the suspect commit, here's
# the PR that introduced it."
#
# Triggers:
#   1. Standalone CLI:  blame-bot.sh [--cluster <id>] [--checks <CSV>]
#   2. Invoked by cluster-detector when ci_failure_cluster fires
#   3. Manual: blame-bot.sh --since-pr <N>  (look back from a known-good PR)
#
# Emits:
#   - kind=regression_attributed (with suspect_commits CSV)
#   - kind=regression_inattributable (when no plausible suspect found)
#
# Output is human-readable by default; --json for structured consumers.
#
# Env:
#   CHUMP_SKIP_BLAME_BOT=1            short-circuits to exit 0
#   CHUMP_BLAME_BOT_LOOKBACK_RUNS     how many recent runs to scan (default 20)
#   CHUMP_BLAME_BOT_MAX_SUSPECTS      max suspects to report per check (default 5)
#   CHUMP_BLAME_BOT_WORKFLOW          gh workflow filename (default ci.yml)
#   CHUMP_AMBIENT_LOG                 override ambient.jsonl path (tests)
#   CHUMP_BLAME_BOT_TEST_GREEN_SHA    test injection: skip gh lookup
#   CHUMP_BLAME_BOT_TEST_REPO_ROOT    test injection: override repo root

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
REPO_ROOT="${CHUMP_BLAME_BOT_TEST_REPO_ROOT:-${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
LOOKBACK="${CHUMP_BLAME_BOT_LOOKBACK_RUNS:-20}"
MAX_SUSPECTS="${CHUMP_BLAME_BOT_MAX_SUSPECTS:-5}"
WORKFLOW="${CHUMP_BLAME_BOT_WORKFLOW:-ci.yml}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
FORMAT=text
CLUSTER_ID=""
CHECKS_CSV=""
SINCE_PR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)      FORMAT=json; shift ;;
        --cluster)   CLUSTER_ID="${2:-}"; shift 2 ;;
        --checks)    CHECKS_CSV="${2:-}"; shift 2 ;;
        --since-pr)  SINCE_PR="${2:-}"; shift 2 ;;
        --help|-h)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *) shift ;;
    esac
done

# ── Bypass ────────────────────────────────────────────────────────────────────
if [[ "${CHUMP_SKIP_BLAME_BOT:-0}" == "1" ]]; then
    [[ "$FORMAT" == "json" ]] && echo '{"status":"skipped"}' || echo "blame-bot: skipped (env bypass)"
    exit 0
fi

mkdir -p "$REPO_ROOT/.chump-locks" 2>/dev/null || true

# ── Helpers ───────────────────────────────────────────────────────────────────
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_emit() {
    local kind="$1"; shift
    local extra=""
    for kv in "$@"; do
        extra+=",${kv}"
    done
    printf '{"ts":"%s","kind":"%s","source":"blame_bot"%s}\n' \
        "$(_ts)" "$kind" "$extra" >> "$AMBIENT" 2>/dev/null || true
}

# ── Find the last-green CI run sha ────────────────────────────────────────────
# Returns the head_sha of the most-recent SUCCESS run on main.
# Falls back to HEAD~N if gh is unavailable.
_find_last_green_sha() {
    if [[ -n "${CHUMP_BLAME_BOT_TEST_GREEN_SHA:-}" ]]; then
        echo "$CHUMP_BLAME_BOT_TEST_GREEN_SHA"
        return
    fi

    if ! command -v gh >/dev/null 2>&1; then
        # Fallback: assume last 5 commits include the green→red transition
        git -C "$REPO_ROOT" rev-parse "HEAD~5" 2>/dev/null || echo ""
        return
    fi

    local sha
    sha="$(gh run list \
        --workflow "$WORKFLOW" \
        --branch main \
        --status success \
        --limit "$LOOKBACK" \
        --json conclusion,headSha,startedAt 2>/dev/null \
        | python3 -c '
import json, sys
try:
    runs = json.load(sys.stdin)
except Exception:
    sys.exit(0)
# Most-recent first; first SUCCESS wins.
for r in runs:
    if r.get("conclusion") == "success":
        print(r.get("headSha",""))
        break
' 2>/dev/null)"

    if [[ -z "$sha" ]]; then
        sha="$(git -C "$REPO_ROOT" rev-parse "HEAD~5" 2>/dev/null || echo "")"
    fi
    echo "$sha"
}

# ── Map check names → likely prod path globs ──────────────────────────────────
# Coarse heuristic. Refines over time as we learn the mapping.
_paths_for_check() {
    local check="$1"
    case "$check" in
        *test*|*cargo*)        echo "src/ scripts/ci/test-*.sh" ;;
        *fast-checks*|*clippy*) echo "src/ Cargo.toml scripts/" ;;
        *audit*)               echo "scripts/ scripts/git-hooks/ src/" ;;
        *ACP*|*acp*)           echo "src/acp src/acp_server" ;;
        *pre-push*|*hook*)     echo "scripts/git-hooks/" ;;
        *)                     echo "src/ scripts/" ;; # default wide
    esac
}

# ── Find suspect commits in green..HEAD touching the given paths ──────────────
_find_suspects() {
    local green_sha="$1"
    local paths="$2"
    [[ -z "$green_sha" ]] && return

    # shellcheck disable=SC2086
    git -C "$REPO_ROOT" log --oneline "${green_sha}..HEAD" -- $paths 2>/dev/null \
        | head -n "$MAX_SUSPECTS" \
        | awk '{print $1}'
}

# ── Resolve commit SHA → PR number via merge commit message ───────────────────
_pr_for_commit() {
    local sha="$1"
    git -C "$REPO_ROOT" log -1 --format='%s' "$sha" 2>/dev/null \
        | grep -oE '#[0-9]+' | head -1 | tr -d '#'
}

# ── Main: attribute clusters → suspects ───────────────────────────────────────
GREEN_SHA="$(_find_last_green_sha)"
if [[ -z "$GREEN_SHA" ]]; then
    [[ "$FORMAT" == "json" ]] && echo '{"status":"no_green_baseline"}' \
        || echo "blame-bot: cannot find a green baseline (no recent successful CI run)"
    _emit "regression_inattributable" \
        "\"reason\":\"no_green_baseline\""
    exit 0
fi

# Determine checks to attribute. Use plain space-joined string for bash 3.2.
CHECKS_LIST=""
if [[ -n "$CHECKS_CSV" ]]; then
    CHECKS_LIST="$(echo "$CHECKS_CSV" | tr ',' ' ')"
elif [[ -n "$CLUSTER_ID" ]]; then
    # Look up the cluster's failing checks from state file (extension; today
    # state doesn't store the check list — fall through to defaults).
    :
fi

# Default: attribute all common checks if none specified.
if [[ -z "$CHECKS_LIST" ]]; then
    CHECKS_LIST="test audit fast-checks"
fi

# Collect suspects per check (bash 3.2 compatible — no assoc arrays).
ALL_SUSPECTS=""
for check in $CHECKS_LIST; do
    paths="$(_paths_for_check "$check")"
    suspects="$(_find_suspects "$GREEN_SHA" "$paths")"
    if [[ -n "$suspects" ]]; then
        ALL_SUSPECTS+="${suspects} "
    fi
done

# Dedup suspects across checks.
DEDUP_SUSPECTS="$(echo "$ALL_SUSPECTS" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')"

# ── Emit + report ─────────────────────────────────────────────────────────────
# Pretty-print CHECKS_LIST as comma-separated for ambient/JSON.
CHECKS_CSV_OUT="$(echo "$CHECKS_LIST" | tr ' ' ',')"

if [[ -z "$DEDUP_SUSPECTS" ]]; then
    _emit "regression_inattributable" \
        "\"reason\":\"no_commits_in_green_to_head_window\"" \
        "\"green_sha\":\"$GREEN_SHA\"" \
        "\"checks\":\"$CHECKS_CSV_OUT\""
    if [[ "$FORMAT" == "json" ]]; then
        echo "{\"status\":\"inattributable\",\"green_sha\":\"$GREEN_SHA\",\"reason\":\"no_commits_in_window\"}"
    else
        echo "blame-bot: no commits in $GREEN_SHA..HEAD touching paths for [$CHECKS_LIST]"
    fi
    exit 0
fi

# Build report
if [[ "$FORMAT" == "json" ]]; then
    python3 -c "
import json
suspects = '$DEDUP_SUSPECTS'.split(',')
green = '$GREEN_SHA'
checks = '$CHECKS_CSV_OUT'.split(',')
out = {
    'status': 'attributed',
    'green_sha': green,
    'checks_attributed': checks,
    'suspect_commits': [s for s in suspects if s],
    'count': len([s for s in suspects if s]),
}
print(json.dumps(out, indent=2))
"
else
    echo "blame-bot: attributing regression vs green=$GREEN_SHA"
    echo "  checks: $CHECKS_LIST"
    echo "  suspect commits (most recent first):"
    for sha in ${DEDUP_SUSPECTS//,/ }; do
        pr="$(_pr_for_commit "$sha")"
        msg="$(git -C "$REPO_ROOT" log -1 --format='%s' "$sha" 2>/dev/null)"
        if [[ -n "$pr" ]]; then
            echo "    $sha  (#$pr)  $msg"
        else
            echo "    $sha           $msg"
        fi
    done
fi

# Single dedupe-friendly suspect string for ambient
_emit "regression_attributed" \
    "\"green_sha\":\"$GREEN_SHA\"" \
    "\"suspect_commits\":\"$DEDUP_SUSPECTS\"" \
    "\"checks_attributed\":\"$CHECKS_CSV_OUT\"" \
    "\"count\":$(echo "$DEDUP_SUSPECTS" | tr ',' '\n' | wc -l | xargs)"

exit 0
