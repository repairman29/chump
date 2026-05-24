#!/usr/bin/env bash
# transient-retrigger.sh — INFRA-1899
#
# Auto-recognizes KNOWN-TRANSIENT CI failure patterns on open PRs and
# pushes an empty commit to force a fresh CI run. Retires the operator
# hand-empty-commit workaround (today's session had 10+ such manual
# retriggers for the audit-cancel pattern alone).
#
# Composes:
#   gh pr list / gh pr view             — discover open PRs + check states
#   gh run view --log-failed             — pull failed-step logs for matching
#   git commit --allow-empty + push      — the retrigger primitive
#   scripts/coord/transient-classes.json — classification catalog
#   .chump-locks/ambient.jsonl           — telemetry stream
#   .chump-locks/transient-retrigger-state.jsonl — per-PR retry ledger
#
# Cap: 2 retries per PR per CHUMP_TRANSIENT_RETRIGGER_WINDOW_S (default 21600 = 6h)
#
# Bypass:
#   CHUMP_TRANSIENT_RETRIGGER_DISABLED=1   — daemon exits 0 immediately
#   PR label `no-auto-retrigger`           — that specific PR is skipped
#
# Tunables:
#   CHUMP_TRANSIENT_RETRIGGER_CAP          default 2     retries per PR per window
#   CHUMP_TRANSIENT_RETRIGGER_WINDOW_S     default 21600 window seconds (6h)
#   CHUMP_TRANSIENT_AMBIENT_LOG            override ambient.jsonl path
#   CHUMP_TRANSIENT_STATE_FILE             override state ledger path
#   CHUMP_TRANSIENT_CATALOG                override transient-classes.json path
#   CHUMP_TRANSIENT_ONCE                   process current state once and exit
#                                           (used by --once flag and CI smoke test)
#   CHUMP_TRANSIENT_MAX_PRS                limit PRs scanned per cycle (default 30)
#   CHUMP_TRANSIENT_MOCK_PR_LIST           CI hook: newline-list of "pr<TAB>headref"
#                                           pairs; bypasses gh pr list
#   CHUMP_TRANSIENT_MOCK_FAILURE_FOR_<N>   CI hook: log text the daemon "sees" for
#                                           PR <N> instead of gh-run-view output
#   CHUMP_TRANSIENT_MOCK_LABELS_FOR_<N>    CI hook: comma-separated labels for PR <N>
#                                           instead of gh-pr-view output
#   CHUMP_TRANSIENT_DRY_RUN                if 1, skip the actual git push but still
#                                           emit ambient and tick the state ledger
#
# Emits ambient events:
#   transient_auto_retriggered  {pr, failure_class, attempt_number}
#
# Exit codes:
#   0 — normal (signal exit, --once done, bypass, or nothing to retrigger)
#   2 — missing dependency (gh, catalog json, etc.)

set -uo pipefail

# ── bypass ────────────────────────────────────────────────────────────────
if [ "${CHUMP_TRANSIENT_RETRIGGER_DISABLED:-0}" = "1" ]; then
    echo "[transient-retrigger] CHUMP_TRANSIENT_RETRIGGER_DISABLED=1 — exiting cleanly"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# INFRA-1274: route GitHub calls through the cache-first wrapper so the
# raw-gh-lint gate stays green (and to inherit retry/criticality logic).
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/github_cache.sh"
AMBIENT_LOG="${CHUMP_TRANSIENT_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
STATE_FILE="${CHUMP_TRANSIENT_STATE_FILE:-$REPO_ROOT/.chump-locks/transient-retrigger-state.jsonl}"
CATALOG="${CHUMP_TRANSIENT_CATALOG:-$REPO_ROOT/scripts/coord/transient-classes.json}"
CAP="${CHUMP_TRANSIENT_RETRIGGER_CAP:-2}"
WINDOW_S="${CHUMP_TRANSIENT_RETRIGGER_WINDOW_S:-21600}"
MAX_PRS="${CHUMP_TRANSIENT_MAX_PRS:-30}"
DRY_RUN="${CHUMP_TRANSIENT_DRY_RUN:-0}"

[ -f "$CATALOG" ] || { echo "ERROR: catalog missing at $CATALOG" >&2; exit 2; }

mkdir -p "$(dirname "$AMBIENT_LOG")" "$(dirname "$STATE_FILE")" 2>/dev/null

# Resolve --once flag.
RUN_ONCE="${CHUMP_TRANSIENT_ONCE:-0}"
if [ "${1:-}" = "--once" ]; then
    RUN_ONCE=1
fi

# ── ambient emit helper ───────────────────────────────────────────────────
emit() {
    local kind="$1"
    local fields="$2"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"%s",%s}\n' "$ts" "$kind" "$fields" >> "$AMBIENT_LOG"
}

# ── count recent retriggers for a PR within window ────────────────────────
recent_retrigger_count() {
    local pr="$1"
    [ -f "$STATE_FILE" ] || { echo 0; return; }
    local now
    now=$(date +%s)
    local window="$WINDOW_S"
    # Use python to do the entire scan to avoid pipefail interactions with
    # an empty/no-match grep producing duplicated fallback "0\n0" output.
    STATE_FILE="$STATE_FILE" PR="$pr" NOW="$now" WINDOW="$window" python3 <<'PY' 2>/dev/null || echo 0
import json, os
state = os.environ.get("STATE_FILE", "")
pr = os.environ.get("PR", "")
now = int(os.environ.get("NOW", "0"))
window = int(os.environ.get("WINDOW", "0"))
count = 0
try:
    with open(state) as h:
        for line in h:
            try:
                e = json.loads(line)
            except Exception:
                continue
            if str(e.get("pr", "")) != pr:
                continue
            ts = int(e.get("unix_ts", 0))
            if now - ts < window:
                count += 1
except FileNotFoundError:
    pass
print(count)
PY
}

mark_retriggered() {
    local pr="$1" failure_class="$2" attempt="$3"
    local unix_ts
    unix_ts=$(date +%s)
    printf '{"unix_ts":%d,"pr":"%s","failure_class":"%s","attempt":%d}\n' \
        "$unix_ts" "$pr" "$failure_class" "$attempt" >> "$STATE_FILE"
}

# ── classify a blob of log text against the catalog ───────────────────────
# Echoes the matched class name (e.g. "audit_cancelled") or empty.
classify_failure() {
    local logtext="$1"
    LOGTEXT="$logtext" CATALOG_FILE="$CATALOG" python3 <<'PY' 2>/dev/null
import json, os, re, sys
text = os.environ.get("LOGTEXT", "")
catalog_path = os.environ.get("CATALOG_FILE", "")
try:
    with open(catalog_path) as h:
        cat = json.load(h)
except Exception:
    sys.exit(0)
for entry in cat.get("classes", []):
    pat = entry.get("pattern", "")
    if not pat:
        continue
    try:
        if re.search(pat, text):
            print(entry.get("class", ""))
            sys.exit(0)
    except re.error:
        continue
PY
}

# ── fetch PR labels (mock-aware) ──────────────────────────────────────────
pr_labels() {
    local pr="$1"
    local var="CHUMP_TRANSIENT_MOCK_LABELS_FOR_$pr"
    local mock="${!var:-}"
    if [ -n "$mock" ]; then
        echo "$mock"
        return
    fi
    chump_gh pr view "$pr" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo ""
}

# ── fetch the failed-log blob for a PR (mock-aware) ───────────────────────
# Returns the joined failure context the classifier scans.
pr_failure_log() {
    local pr="$1"
    local var="CHUMP_TRANSIENT_MOCK_FAILURE_FOR_$pr"
    local mock="${!var:-}"
    if [ -n "$mock" ]; then
        echo "$mock"
        return
    fi
    # Real path: get the latest failing check-run, then pull its log.
    local run_id
    run_id=$(gh pr checks "$pr" --json name,state,link --jq \
        '.[] | select(.state=="FAILURE") | .link' 2>/dev/null \
        | head -1 \
        | sed -E 's|.*/runs/([0-9]+).*|\1|' || echo "")
    if [ -z "$run_id" ]; then
        # Fallback: include the check-run summary itself (name + conclusion).
        gh pr checks "$pr" 2>/dev/null | grep -iE 'fail|cancel' | head -20
        return
    fi
    gh run view "$run_id" --log-failed 2>/dev/null | tail -200
}

# ── list candidate open PRs to scan (mock-aware) ──────────────────────────
# Prints "pr<TAB>headref" pairs.
list_candidate_prs() {
    local mock="${CHUMP_TRANSIENT_MOCK_PR_LIST:-}"
    if [ -n "$mock" ]; then
        printf '%s\n' "$mock"
        return
    fi
    chump_gh pr list --state open --limit "$MAX_PRS" \
        --json number,headRefName,statusCheckRollup \
        --jq '.[] | select((.statusCheckRollup // []) | map(select(.conclusion=="FAILURE" or .conclusion=="CANCELLED")) | length > 0) | "\(.number)\t\(.headRefName)"' \
        2>/dev/null || true
}

# ── push an empty commit on the PR's head branch ──────────────────────────
push_empty_commit() {
    local pr="$1" headref="$2" failure_class="$3"
    if [ "$DRY_RUN" = "1" ]; then
        echo "[transient-retrigger] DRY_RUN=1: would push empty commit for PR=$pr ref=$headref class=$failure_class"
        return 0
    fi
    local tmp_wt
    tmp_wt=$(mktemp -d -t chump-retrig-pr$pr.XXXXXX)
    # Clean up worktree on exit of this function call.
    # shellcheck disable=SC2064
    trap "git -C '$REPO_ROOT' worktree remove --force '$tmp_wt' >/dev/null 2>&1 || rm -rf '$tmp_wt'" RETURN
    if ! git -C "$REPO_ROOT" fetch origin "$headref" --quiet 2>/dev/null; then
        echo "[transient-retrigger] WARN: fetch failed for $headref (PR=$pr)" >&2
        return 1
    fi
    if ! git -C "$REPO_ROOT" worktree add --quiet "$tmp_wt" "origin/$headref" 2>/dev/null; then
        echo "[transient-retrigger] WARN: worktree add failed for $headref (PR=$pr)" >&2
        return 1
    fi
    git -C "$tmp_wt" checkout -B "$headref" >/dev/null 2>&1 || true
    if ! git -C "$tmp_wt" commit --allow-empty \
        -m "ci: transient-retrigger $failure_class

INFRA-1899 auto-retrigger for PR #$pr (failure class: $failure_class).
Pushed by scripts/coord/transient-retrigger.sh.
Disable per-PR with label \`no-auto-retrigger\`; disable globally with
CHUMP_TRANSIENT_RETRIGGER_DISABLED=1." >/dev/null 2>&1; then
        echo "[transient-retrigger] WARN: empty-commit failed (PR=$pr)" >&2
        return 1
    fi
    if ! git -C "$tmp_wt" push origin "$headref" --force-with-lease >/dev/null 2>&1; then
        echo "[transient-retrigger] WARN: push failed (PR=$pr ref=$headref)" >&2
        return 1
    fi
    return 0
}

# ── process one PR ────────────────────────────────────────────────────────
process_pr() {
    local pr="$1" headref="$2"

    # Per-PR opt-out via label.
    local labels
    labels=$(pr_labels "$pr")
    if echo ",${labels}," | grep -q ",no-auto-retrigger,"; then
        return
    fi

    # Cap check.
    local count
    count=$(recent_retrigger_count "$pr")
    count=${count:-0}
    if [ "$count" -ge "$CAP" ]; then
        # Capped — don't classify, don't emit (avoid log spam on stuck PRs).
        return
    fi

    # Classify the failure.
    local logtext failure_class
    logtext=$(pr_failure_log "$pr")
    if [ -z "$logtext" ]; then
        return
    fi
    failure_class=$(classify_failure "$logtext")
    if [ -z "$failure_class" ]; then
        # Unknown failure — operator-class, skip.
        return
    fi

    local attempt=$(( count + 1 ))
    if push_empty_commit "$pr" "$headref" "$failure_class"; then
        mark_retriggered "$pr" "$failure_class" "$attempt"
        # scanner-anchor: "kind":"transient_auto_retriggered"
        emit "transient_auto_retriggered" \
            "\"pr\":\"$pr\",\"failure_class\":\"$failure_class\",\"attempt_number\":$attempt"
    fi
}

# ── one cycle ─────────────────────────────────────────────────────────────
run_one_cycle() {
    local line pr headref
    while IFS=$'\t' read -r pr headref; do
        [ -n "$pr" ] || continue
        process_pr "$pr" "$headref"
    done < <(list_candidate_prs)
}

# ── main ──────────────────────────────────────────────────────────────────
if [ "$RUN_ONCE" = "1" ]; then
    run_one_cycle
    exit 0
fi

# launchd invokes us every StartInterval=300s, so we just run one cycle and
# exit; no internal loop. (Matches install-*-launchd.sh convention.)
echo "[transient-retrigger] starting (cap=$CAP/${WINDOW_S}s catalog=$CATALOG)"
run_one_cycle
exit 0
