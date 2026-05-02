#!/usr/bin/env bash
# stale-pr-reaper.sh — Auto-close PRs whose gap work is already on main.
#
# Run hourly (via launchd or cron) or manually to keep the PR queue clean.
# The root problem it solves: an agent works on a branch for hours, meanwhile
# another agent pushes the same gap directly to main. The branch PR becomes
# stale dead-weight; CI keeps running; future agents see open gaps that are
# actually done.
#
# What it does:
#   1. Lists all open PRs via gh CLI.
#   2. For each PR: extracts gap IDs from the title and its commits vs main.
#   3. Reads docs/gaps.yaml from origin/main.
#   4. Closes the PR if ALL cited gaps are `done` on main AND the branch is
#      more than STALE_BEHIND_THRESHOLD commits behind main.
#   5. Warns (but does not close) on PRs that are very stale with open gaps —
#      those need a manual rebase decision.
#
# Usage:
#   ./scripts/ops/stale-pr-reaper.sh              # live run
#   ./scripts/ops/stale-pr-reaper.sh --dry-run    # print what would happen, no changes
#
# Environment:
#   REMOTE                 git remote (default: origin)
#   BASE                   base branch (default: main)
#   STALE_BEHIND_THRESHOLD max commits a PR can be behind before it's considered
#                          stale (default: 15). All-done PRs above this are closed.
#   WARN_BEHIND_THRESHOLD  commits behind at which a warning is issued even if
#                          gaps are not fully done (default: 25).

set -euo pipefail

# INFRA-120: shared instrumentation (heartbeat + ambient reaper_run event +
# log rotation). Sourced from scripts/lib/ so all reapers share the same
# emit/rotate path; the watchdog reads /tmp/chump-reaper-<NAME>.heartbeat.
# shellcheck source=../lib/reaper-instrumentation.sh
source "$(dirname "$0")/../lib/reaper-instrumentation.sh"
reaper_setup pr
reaper_rotate_log /tmp/chump-stale-pr-reaper.out.log
reaper_rotate_log /tmp/chump-stale-pr-reaper.err.log
trap 'rc=$?; [[ $rc -ne 0 ]] && reaper_finish fail "{\"exit\":$rc}"' EXIT

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

REMOTE="${REMOTE:-origin}"
BASE="${BASE:-main}"
STALE_BEHIND_THRESHOLD="${STALE_BEHIND_THRESHOLD:-15}"
WARN_BEHIND_THRESHOLD="${WARN_BEHIND_THRESHOLD:-25}"

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
warn()  { printf '\033[0;33m  WARN: %s\033[0m\n' "$*"; }
dry()   { printf '  [dry-run] %s\n' "$*"; }

green "=== stale-pr-reaper (base: $REMOTE/$BASE) ==="
[[ $DRY_RUN -eq 1 ]] && info "Dry-run mode — no PRs will be closed."

# Fetch main and all PR branches
git fetch "$REMOTE" "$BASE" --quiet 2>/dev/null || {
    red "Could not fetch $REMOTE/$BASE — aborting."; exit 1
}

# INFRA-219 (2026-05-02): the source of truth on origin/main is per-file
# `docs/gaps/<ID>.yaml` (post-INFRA-188 deletion of the monolith). The
# previous implementation read `docs/gaps.yaml` and would silently abort
# on every modern run; worse, when wired against a local state.db it
# would false-close filing PRs (the gap exists in local DB precisely
# because the PR being inspected reserved it). The fix here:
#
#   1. gap_status() queries `git show origin/main:docs/gaps/<ID>.yaml`
#      directly, NEVER local state. Returns "" if the gap isn't on main.
#   2. Filing PRs (titled "chore(gaps): file ..." / "chore(gaps): reserve
#      ...") are skipped entirely. They cannot be duplicates of themselves.
#
# Optional monolith fallback — only used if `docs/gaps.yaml` still exists
# on $REMOTE/$BASE (i.e. some downstream fork hasn't yet absorbed
# INFRA-188). The post-INFRA-188 path is the canonical one.
GAPS_YAML_LEGACY=$(git show "$REMOTE/$BASE:docs/gaps.yaml" 2>/dev/null || true)

# gap_status GAP_ID — returns the status field value, querying ONLY
# origin/main (never local state.db). Empty string if the gap is not on
# main. Looks up per-file YAML first (canonical post-INFRA-188), falls
# back to the monolith only if it still exists.
gap_status() {
    local gid="$1"
    local per_file
    per_file=$(git show "$REMOTE/$BASE:docs/gaps/${gid}.yaml" 2>/dev/null || true)
    if [[ -n "$per_file" ]]; then
        # Per-file format: top-level list with one entry. Indented
        # under "- id:" so status: is at column 2 (vs column 4 in the
        # legacy monolith). Match either indentation defensively.
        echo "$per_file" | awk '
            /^- id:/{f=1; next}
            f && /^[[:space:]]+status:[[:space:]]/{
                sub(/^[[:space:]]+status:[[:space:]]*/,""); print; exit
            }'
        return
    fi
    if [[ -n "$GAPS_YAML_LEGACY" ]]; then
        echo "$GAPS_YAML_LEGACY" | awk \
            "/^  - id: ${gid}\$/{f=1} f && /^    status:/{sub(/^    status: */,\"\"); print; exit}"
    fi
}

# is_filing_pr_title TITLE — returns 0 if the PR title looks like a gap
# filing PR (whose only intent is to add a `docs/gaps/<ID>.yaml` row).
# Filing PRs are NEVER duplicates of themselves — even if local state.db
# has the gap (because `chump gap reserve` put it there), origin/main
# does not yet, and that's exactly what the PR is about to fix.
is_filing_pr_title() {
    local title="$1"
    case "$title" in
        "chore(gaps): file "*|"chore(gaps): reserve "*) return 0 ;;
        *) return 1 ;;
    esac
}

# List open PRs (number branch title)
PRS=$(gh pr list --json number,title,headRefName \
    --jq '.[] | "\(.number)\t\(.headRefName)\t\(.title)"' 2>/dev/null || true)

if [[ -z "$PRS" ]]; then
    info "No open PRs found."
    green "=== reaper done (nothing to do) ==="
    exit 0
fi

CLOSED=0
WARNED=0

while IFS=$'\t' read -r PR_NUM PR_BRANCH PR_TITLE; do
    info "PR #$PR_NUM  branch=$PR_BRANCH"
    info "  title: $PR_TITLE"

    # INFRA-219: filing PRs are never duplicates of themselves. Their
    # entire purpose is to land a new `docs/gaps/<ID>.yaml` on origin/main.
    # Local state.db already has the row (because `chump gap reserve`
    # put it there before pushing). Closing the PR strands the gap
    # local-only forever — the exact incident from PR #718 (2026-05-02).
    if is_filing_pr_title "$PR_TITLE"; then
        info "  → Filing PR (chore(gaps): file/reserve …) — skipping reaper checks."
        continue
    fi

    # Fetch the PR branch; skip if unreachable (deleted remote etc.)
    if ! git fetch "$REMOTE" "$PR_BRANCH" --quiet 2>/dev/null; then
        warn "Could not fetch $REMOTE/$PR_BRANCH — skipping."
        continue
    fi

    BEHIND=$(git rev-list --count \
        "$REMOTE/$PR_BRANCH..$REMOTE/$BASE" 2>/dev/null || echo 0)
    AHEAD=$(git rev-list --count \
        "$REMOTE/$BASE..$REMOTE/$PR_BRANCH" 2>/dev/null || echo 0)
    info "  commits: +${AHEAD} ahead / -${BEHIND} behind $BASE"

    # Extract gap IDs from: PR title + commits on the branch vs main.
    COMMIT_MSGS=$(git log "$REMOTE/$BASE..$REMOTE/$PR_BRANCH" \
        --oneline 2>/dev/null | head -30 || true)
    GAP_IDS=$(printf '%s\n%s\n' "$PR_TITLE" "$COMMIT_MSGS" \
        | grep -oE '\b[A-Z]+-[0-9]+\b' | sort -u || true)

    if [[ -z "$GAP_IDS" ]]; then
        if [[ "$BEHIND" -gt "$WARN_BEHIND_THRESHOLD" ]]; then
            warn "PR #$PR_NUM is $BEHIND commits behind main with no gap IDs — review manually."
            WARNED=$((WARNED + 1))
        else
            info "  No gap IDs found; nothing to check."
        fi
        continue
    fi

    info "  Gap IDs: $(echo $GAP_IDS | tr '\n' ' ')"

    ALL_DONE=1
    DONE_LIST=""
    OPEN_LIST=""

    for GID in $GAP_IDS; do
        STATUS=$(gap_status "$GID")
        if [[ -z "$STATUS" ]]; then
            info "  $GID — not in gaps.yaml (new gap or ID not matching)"
            ALL_DONE=0
            OPEN_LIST="$OPEN_LIST $GID(?)"
        elif [[ "$STATUS" == "done" ]]; then
            DONE_LIST="$DONE_LIST $GID"
        else
            ALL_DONE=0
            OPEN_LIST="$OPEN_LIST $GID($STATUS)"
        fi
    done

    DONE_LIST="${DONE_LIST# }"
    OPEN_LIST="${OPEN_LIST# }"

    if [[ $ALL_DONE -eq 1 && "$BEHIND" -gt "$STALE_BEHIND_THRESHOLD" ]]; then
        red "  → STALE: all gaps done on main [$DONE_LIST], $BEHIND commits behind."
        CLOSE_MSG="Auto-closing: every gap this PR was working on (${DONE_LIST}) is already \`done\` on \`main\` — the work landed via another agent's commits. The branch is **${BEHIND} commits behind** \`${BASE}\`. Nothing is lost; the code is on main.

Run \`scripts/coord/gap-preflight.sh ${DONE_LIST// / }\` to confirm, then pick a new open gap from \`docs/gaps.yaml\`."
        if [[ $DRY_RUN -eq 1 ]]; then
            dry "gh pr close $PR_NUM --comment \"...\""
        else
            gh pr close "$PR_NUM" --comment "$CLOSE_MSG"
            green "  Closed PR #$PR_NUM."
        fi
        CLOSED=$((CLOSED + 1))

    elif [[ $ALL_DONE -eq 1 && "$BEHIND" -gt 0 ]]; then
        info "  All gaps done [$DONE_LIST] but only $BEHIND commits behind — needs rebase, not closure."
        info "  Hint: git rebase origin/$BASE && git push --force-with-lease"

    elif [[ "$BEHIND" -gt "$WARN_BEHIND_THRESHOLD" ]]; then
        warn "PR #$PR_NUM is $BEHIND commits behind main. Open gaps: $OPEN_LIST"
        warn "Rebase needed: git fetch && git rebase origin/$BASE"
        WARNED=$((WARNED + 1))

    else
        info "  → Active: open gaps [$OPEN_LIST], $BEHIND behind — OK."
    fi

done <<< "$PRS"

echo ""
green "=== reaper done: $CLOSED closed, $WARNED warnings ==="

# INFRA-120: stamp heartbeat + emit reaper_run event. Disarm trap first so we
# don't double-emit on the EXIT trap.
trap - EXIT
reaper_finish ok "{\"closed\":$CLOSED,\"warned\":$WARNED}"
