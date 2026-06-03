#!/usr/bin/env bash
# scripts/coord/blame-bot.sh — INFRA-1989 (THE FLOOR Phase 1 finisher)
# CREDIBLE-080: stale green_sha fix (advance baseline, dedupe, stale-warning)
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
#   - kind=blame_bot_self_resolved (CREDIBLE-080: check_class resolved by later commit)
#   - kind=blame_bot_dedupe_skip (CREDIBLE-080: same tuple emitted in last 30 min)
#   - kind=blame_bot_baseline_stale (CREDIBLE-080: green_sha >50 commits behind HEAD)
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
#   CHUMP_BLAME_BOT_DEDUPE_WINDOW_S   dedupe window in seconds (default 1800 = 30 min)
#   CHUMP_BLAME_BOT_STALE_THRESHOLD   behind-commits threshold for stale warning (default 50)
#   CHUMP_BLAME_BOT_STALE_WINDOW_S    min seconds between stale-baseline emits (default 600)
#   CHUMP_BLAME_BOT_TEST_CHECK_RUNS   test injection: JSON map of sha→check_runs (skip gh API)

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
REPO_ROOT="${CHUMP_BLAME_BOT_TEST_REPO_ROOT:-${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
LOOKBACK="${CHUMP_BLAME_BOT_LOOKBACK_RUNS:-20}"
MAX_SUSPECTS="${CHUMP_BLAME_BOT_MAX_SUSPECTS:-5}"
WORKFLOW="${CHUMP_BLAME_BOT_WORKFLOW:-ci.yml}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
DEDUPE_WINDOW_S="${CHUMP_BLAME_BOT_DEDUPE_WINDOW_S:-1800}"
STALE_THRESHOLD="${CHUMP_BLAME_BOT_STALE_THRESHOLD:-50}"
STALE_WINDOW_S="${CHUMP_BLAME_BOT_STALE_WINDOW_S:-600}"
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
            sed -n '2,35p' "$0"
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

_ts_epoch() {
    # macOS-compatible: date -u +%s
    date -u +%s 2>/dev/null || python3 -c 'import time; print(int(time.time()))' 2>/dev/null || echo "0"
}

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

# ── CREDIBLE-080 AC#1: Check if a later commit resolves a failing check_class ─
# Scans commits in green_sha..HEAD; for each commit queries check-runs;
# returns the SHA of the first commit where the check_class is all-success.
# Uses CHUMP_BLAME_BOT_TEST_CHECK_RUNS (JSON file path) for test injection.
# In production, queries gh api repos/OWNER/REPO/commits/SHA/check-runs.
_check_intermediate_green() {
    local original_green_sha="$1"
    local check_class="$2"
    local resolving_sha=""

    # List commits in window oldest-first (reverse) so we find earliest fix
    # Use full SHAs (%H) to match what git rev-parse / gh API returns
    local commits
    commits="$(git -C "$REPO_ROOT" log --format='%H' --reverse "${original_green_sha}..HEAD" 2>/dev/null)"
    if [[ -z "$commits" ]]; then
        return
    fi

    for sha in $commits; do
        local checks_all_success=0
        if [[ -n "${CHUMP_BLAME_BOT_TEST_CHECK_RUNS:-}" ]]; then
            # Test injection: CHUMP_BLAME_BOT_TEST_CHECK_RUNS is a JSON file:
            # {"<sha>": [{"name": "test", "conclusion": "success"}, ...], ...}
            checks_all_success="$(python3 -c "
import json, sys
try:
    with open('$CHUMP_BLAME_BOT_TEST_CHECK_RUNS') as f:
        data = json.load(f)
    runs = data.get('$sha', [])
    # filter to runs whose name contains the check_class
    matching = [r for r in runs if '$check_class' in r.get('name','')]
    if matching and all(r.get('conclusion') == 'success' for r in matching):
        print('1')
    else:
        print('0')
except Exception as e:
    print('0')
" 2>/dev/null || echo "0")"
        elif command -v gh >/dev/null 2>&1; then
            # Production: query GitHub check-runs for this commit
            # Get repo owner/name from remote
            local repo_nwo
            repo_nwo="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
                | sed 's|.*github.com[:/]\(.*\)\.git|\1|; s|.*github.com[:/]\(.*\)|\1|' 2>/dev/null || echo "")"
            if [[ -n "$repo_nwo" ]]; then
                checks_all_success="$(gh api "repos/${repo_nwo}/commits/${sha}/check-runs" \
                    --jq ".check_runs | map(select(.name | test(\"${check_class}\"; \"i\"))) | if length > 0 and (map(.conclusion == \"success\") | all) then \"1\" else \"0\" end" \
                    2>/dev/null | head -1 | tr -d '[:space:]' || echo "0")"
            fi
        fi

        if [[ "$checks_all_success" == "1" ]]; then
            resolving_sha="$sha"
            break
        fi
    done

    echo "$resolving_sha"
}

# ── CREDIBLE-080 AC#2: Dedupe regression_attributed by tuple hash (30 min) ────
# Returns 0 if the tuple was already emitted within the window (should skip).
# Returns 1 if new / past the window (should emit).
_is_duplicate_emission() {
    local green_sha="$1"
    local suspect_commits="$2"
    local checks_attributed="$3"

    # Build a deterministic hash of the tuple
    local tuple_str="${green_sha}|${suspect_commits}|${checks_attributed}"
    local tuple_hash
    tuple_hash="$(printf '%s' "$tuple_str" | md5sum 2>/dev/null | awk '{print $1}' \
        || printf '%s' "$tuple_str" | md5 2>/dev/null | awk '{print $1}' \
        || printf '%s' "$tuple_str" | python3 -c 'import sys,hashlib; print(hashlib.md5(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null \
        || echo "no_hash")"

    if [[ "$tuple_hash" == "no_hash" ]]; then
        return 1  # can't hash → treat as new
    fi

    local now_epoch
    now_epoch="$(_ts_epoch)"
    local window_start
    window_start="$((now_epoch - DEDUPE_WINDOW_S))"

    # Scan recent ambient events for matching tuple_hash within window
    if [[ -f "$AMBIENT" ]]; then
        local found
        found="$(python3 -c "
import json, sys

try:
    window_start = $window_start
    target_hash = '$tuple_hash'
    with open('$AMBIENT') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                evt = json.loads(line)
            except Exception:
                continue
            if evt.get('kind') not in ('regression_attributed', 'blame_bot_dedupe_skip'):
                continue
            # Check timestamp
            ts = evt.get('ts', '')
            # Parse ISO8601 timestamp to epoch
            try:
                import datetime
                dt = datetime.datetime.strptime(ts, '%Y-%m-%dT%H:%M:%SZ')
                evt_epoch = int(dt.replace(tzinfo=datetime.timezone.utc).timestamp())
                if evt_epoch < window_start:
                    continue
            except Exception:
                continue
            if evt.get('tuple_hash') == target_hash:
                print('1')
                sys.exit(0)
except Exception:
    pass
print('0')
" 2>/dev/null || echo "0")"
        if [[ "$found" == "1" ]]; then
            # Emit dedupe-skip signal
            _emit "blame_bot_dedupe_skip" \
                "\"reason\":\"already_emitted\"" \
                "\"tuple_hash\":\"${tuple_hash}\""
            return 0
        fi
    fi
    echo "$tuple_hash"
    return 1
}

# ── CREDIBLE-080 AC#3/#5: Count commits between green_sha and HEAD ────────────
_commits_behind() {
    local green_sha="$1"
    git -C "$REPO_ROOT" rev-list --count "${green_sha}..HEAD" 2>/dev/null || echo "0"
}

# ── CREDIBLE-080 AC#5: Emit stale-baseline warning (debounced) ────────────────
_maybe_emit_stale_baseline() {
    local green_sha="$1"
    local behind_count="$2"

    # Debounce: skip if we emitted within STALE_WINDOW_S
    local now_epoch
    now_epoch="$(_ts_epoch)"
    local window_start
    window_start="$((now_epoch - STALE_WINDOW_S))"

    if [[ -f "$AMBIENT" ]]; then
        local recent_stale
        recent_stale="$(python3 -c "
import json, sys, datetime
try:
    window_start = $window_start
    with open('$AMBIENT') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                evt = json.loads(line)
            except Exception:
                continue
            if evt.get('kind') != 'blame_bot_baseline_stale':
                continue
            ts = evt.get('ts', '')
            try:
                dt = datetime.datetime.strptime(ts, '%Y-%m-%dT%H:%M:%SZ')
                evt_epoch = int(dt.replace(tzinfo=datetime.timezone.utc).timestamp())
                if evt_epoch >= window_start:
                    print('1')
                    sys.exit(0)
            except Exception:
                continue
except Exception:
    pass
print('0')
" 2>/dev/null || echo "0")"
        if [[ "$recent_stale" == "1" ]]; then
            return  # already emitted recently, skip
        fi
    fi

    echo "blame-bot: WARNING — green_sha may be stale, re-baseline (${behind_count} commits behind HEAD)"
    _emit "blame_bot_baseline_stale" \
        "\"green_sha\":\"${green_sha}\"" \
        "\"behind_commits\":${behind_count}"
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

# ── CREDIBLE-080 AC#5: Stale baseline check ───────────────────────────────────
BEHIND_COUNT="$(_commits_behind "$GREEN_SHA")"
if [[ "$BEHIND_COUNT" -gt "$STALE_THRESHOLD" ]]; then
    _maybe_emit_stale_baseline "$GREEN_SHA" "$BEHIND_COUNT"
fi

# ── CREDIBLE-080 AC#1: Check if any intermediate commit resolved failing checks ─
# Per-check resolution tracking: accumulate resolved and still-failing checks
RESOLVED_CHECKS=""
UNRESOLVED_CHECKS=""
RESOLVING_COMMITS=""

for check in $CHECKS_LIST; do
    resolving_sha="$(_check_intermediate_green "$GREEN_SHA" "$check")"
    if [[ -n "$resolving_sha" ]]; then
        RESOLVED_CHECKS="${RESOLVED_CHECKS:+$RESOLVED_CHECKS,}$check"
        RESOLVING_COMMITS="${RESOLVING_COMMITS:+$RESOLVING_COMMITS,}$resolving_sha"
    else
        UNRESOLVED_CHECKS="${UNRESOLVED_CHECKS:+$UNRESOLVED_CHECKS,}$check"
    fi
done

# AC#2: If all checks are resolved, emit self-resolved and skip regression_attributed
if [[ -n "$RESOLVED_CHECKS" && -z "$UNRESOLVED_CHECKS" ]]; then
    # All checks resolved — emit self-resolved, do NOT emit regression_attributed
    # Use the first resolving commit as the primary (per check, it advanced the baseline)
    FIRST_RESOLVING="$(echo "$RESOLVING_COMMITS" | cut -d',' -f1)"
    _emit "blame_bot_self_resolved" \
        "\"original_green_sha\":\"${GREEN_SHA}\"" \
        "\"new_green_sha\":\"${FIRST_RESOLVING}\"" \
        "\"check_class\":\"${RESOLVED_CHECKS}\"" \
        "\"resolving_commit\":\"${RESOLVING_COMMITS}\""
    if [[ "$FORMAT" == "json" ]]; then
        echo "{\"status\":\"self_resolved\",\"original_green_sha\":\"$GREEN_SHA\",\"resolved_checks\":\"$RESOLVED_CHECKS\",\"resolving_commits\":\"$RESOLVING_COMMITS\"}"
    else
        echo "blame-bot: all checks self-resolved — ${RESOLVED_CHECKS} resolved by ${RESOLVING_COMMITS}"
        echo "  (no regression_attributed emitted — baseline advanced)"
    fi
    exit 0
fi

# Some or all checks remain unresolved — use original green_sha for those
# Narrow check list to only unresolved ones
if [[ -n "$UNRESOLVED_CHECKS" ]]; then
    CHECKS_LIST_FOR_SUSPECTS="$(echo "$UNRESOLVED_CHECKS" | tr ',' ' ')"
else
    # No per-check test data — fall through to full attribution
    CHECKS_LIST_FOR_SUSPECTS="$CHECKS_LIST"
fi

# Collect suspects per check (bash 3.2 compatible — no assoc arrays).
ALL_SUSPECTS=""
for check in $CHECKS_LIST_FOR_SUSPECTS; do
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

# ── CREDIBLE-080 AC#3: Dedupe regression_attributed by tuple ─────────────────
# Build the hash for this tuple and check if we've emitted it in the last 30min
TUPLE_HASH_OR_SKIP="$(_is_duplicate_emission "$GREEN_SHA" "$DEDUP_SUSPECTS" "$CHECKS_CSV_OUT")"
DEDUPE_RC=$?

if [[ $DEDUPE_RC -eq 0 ]]; then
    # Duplicate — blame_bot_dedupe_skip already emitted inside _is_duplicate_emission
    if [[ "$FORMAT" != "json" ]]; then
        echo "blame-bot: skipping regression_attributed emit (same tuple seen in last ${DEDUPE_WINDOW_S}s)"
    fi
    exit 0
fi

# TUPLE_HASH_OR_SKIP contains the hash when not a duplicate (rc=1 means not dup)
TUPLE_HASH="${TUPLE_HASH_OR_SKIP}"

# Single dedupe-friendly suspect string for ambient (with tuple_hash for future lookups)
_emit "regression_attributed" \
    "\"green_sha\":\"$GREEN_SHA\"" \
    "\"suspect_commits\":\"$DEDUP_SUSPECTS\"" \
    "\"checks_attributed\":\"$CHECKS_CSV_OUT\"" \
    "\"count\":$(echo "$DEDUP_SUSPECTS" | tr ',' '\n' | wc -l | xargs)" \
    "\"tuple_hash\":\"${TUPLE_HASH}\""

exit 0
