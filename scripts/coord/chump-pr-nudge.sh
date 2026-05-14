#!/usr/bin/env bash
# chump-pr-nudge.sh — Auto-diagnose a stuck GitHub PR and post a structured
# comment with the recipe to land it (INFRA-1117).
#
# Mechanizes the manual nudge pattern we've been doing by hand: 13 dirty PRs
# got identical "rebase + REST-merge" comments earlier today.
#
# Usage:
#   chump-pr-nudge.sh <PR>                  # diagnose + post (with cooldown)
#   chump-pr-nudge.sh <PR> --dry-run        # print comment, don't post
#   chump-pr-nudge.sh <PR> --force          # skip cooldown
#   chump-pr-nudge.sh --all-dirty           # batch: nudge every dirty PR
#   chump-pr-nudge.sh --all-orphan          # batch: nudge every orphan-tagged PR
#   chump-pr-nudge.sh --all-blocked-ci      # batch: nudge every PR with failing required CI
#   chump-pr-nudge.sh --stats               # print per-class counts from history
#
# History: .chump-locks/pr-nudge-history.jsonl
#   {ts, pr, sha, class, posted, dry_run}
#
# Cooldown: same (pr, sha, class) within CHUMP_NUDGE_COOLDOWN_HOURS (default 24h)
# is skipped with a NOTE. --force bypasses.
#
# Emits kind=pr_nudged to ambient.jsonl on every post.
# Uses chump_gh (scripts/coord/lib/github.sh) for all REST calls so
# INFRA-1079 throttle + INFRA-1080 preempt apply.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
HISTORY="$LOCK_DIR/pr-nudge-history.jsonl"
AMBIENT="$LOCK_DIR/ambient.jsonl"
TEMPLATE_DIR="$SCRIPT_DIR/pr-nudge-templates"
COOLDOWN_HOURS="${CHUMP_NUDGE_COOLDOWN_HOURS:-24}"

# Source chump_gh wrapper so REST calls flow through INFRA-1079/1080 throttle.
# Falls back to bare gh if the lib isn't available.
if [[ -r "$SCRIPT_DIR/lib/github.sh" ]]; then
    # shellcheck disable=SC1091
    CHUMP_GH_SCRIPT="chump-pr-nudge.sh" source "$SCRIPT_DIR/lib/github.sh"
fi
if ! command -v chump_gh >/dev/null 2>&1; then
    chump_gh() { gh "$@"; }
fi

# Resolve owner/repo from origin remote for gh api paths.
OWNER_REPO="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
    | sed -E 's#.*github.com[:/]([^/]+/[^/.]+).*#\1#')"

usage() {
    sed -n '2,30p' "$0"
    exit 0
}

# Classify a PR. Args: <pr>. Echoes "<class>|<sha>|<failing_required>".
# Class names match template filenames in pr-nudge-templates/.
classify_pr() {
    local pr="$1"
    local meta sha mergeable_state state
    meta="$(chump_gh api "repos/$OWNER_REPO/pulls/$pr" 2>/dev/null)" || return 1
    sha="$(printf '%s' "$meta" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('head',{}).get('sha',''))")"
    mergeable_state="$(printf '%s' "$meta" | python3 -c "import json,sys; print(json.load(sys.stdin).get('mergeable_state',''))")"
    state="$(printf '%s' "$meta" | python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))")"
    [[ "$state" == "open" ]] || { echo ""; return 0; }

    # Pull check-runs and find any required-check failures. Required checks
    # match the names we've seen on this repo's branch protection.
    local checks failing
    checks="$(chump_gh api "repos/$OWNER_REPO/commits/$sha/check-runs" --paginate 2>/dev/null)"
    failing="$(printf '%s' "$checks" | python3 -c "
import json,sys
data = json.load(sys.stdin)
runs = data.get('check_runs', [])
req = {'test','audit'}
# 'ACP protocol smoke test (Zed / JetBrains compatible)' starts with 'ACP'.
fails = []
for r in runs:
    name = r.get('name','')
    is_required = name in req or name.startswith('ACP')
    if is_required and r.get('conclusion') == 'failure':
        fails.append(name)
print(','.join(fails))
")"

    # Auto-merge state.
    local auto_merge
    auto_merge="$(printf '%s' "$meta" | python3 -c "import json,sys; d=json.load(sys.stdin); print('1' if d.get('auto_merge') else '0')")"

    local class=""
    case "$mergeable_state" in
        dirty)   class="dirty" ;;
        blocked)
            if [[ -n "$failing" ]]; then
                class="blocked-ci"
            else
                class="base-modified"
            fi
            ;;
        clean|unstable)
            if [[ "$auto_merge" == "0" ]]; then
                class="clean-not-merged"
            else
                class=""  # has auto-merge armed; not stuck
            fi
            ;;
        *) class="" ;;
    esac

    # Orphan override: any class becomes orphan-disarmed if no auto-merge AND
    # last-commit age exceeds 6h. Reads commit-list head ts.
    if [[ "$auto_merge" == "0" && -n "$class" ]]; then
        local last_ts
        last_ts="$(chump_gh api "repos/$OWNER_REPO/pulls/$pr/commits" --paginate 2>/dev/null \
            | python3 -c "
import json,sys
commits = json.load(sys.stdin)
if not commits:
    print('')
else:
    ts = commits[-1].get('commit',{}).get('committer',{}).get('date','')
    print(ts)
")"
        if [[ -n "$last_ts" ]]; then
            local age_h
            age_h="$(python3 -c "
from datetime import datetime, timezone
import sys
ts = sys.argv[1].replace('Z','+00:00')
try:
    dt = datetime.fromisoformat(ts)
    print(int((datetime.now(timezone.utc) - dt).total_seconds() / 3600))
except Exception:
    print(0)
" "$last_ts")"
            if [[ "$age_h" -ge 6 ]]; then
                class="orphan-disarmed"
            fi
        fi
    fi

    echo "${class}|${sha}|${failing}"
}

# Cooldown check. Args: pr, sha, class. Returns 0 if a recent nudge exists.
recent_nudge_exists() {
    local pr="$1" sha="$2" class="$3"
    [[ -f "$HISTORY" ]] || return 1
    python3 - "$HISTORY" "$pr" "$sha" "$class" "$COOLDOWN_HOURS" <<'PY'
import json, sys
from datetime import datetime, timezone, timedelta
path, pr, sha, klass, hours = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
cutoff = datetime.now(timezone.utc) - timedelta(hours=hours)
try:
    with open(path) as f:
        for line in f:
            try: rec = json.loads(line)
            except Exception: continue
            if str(rec.get('pr')) != pr: continue
            if rec.get('sha') != sha: continue
            if rec.get('class') != klass: continue
            ts = rec.get('ts','').replace('Z','+00:00')
            try:
                dt = datetime.fromisoformat(ts)
            except Exception:
                continue
            if dt > cutoff:
                sys.exit(0)
except FileNotFoundError:
    pass
sys.exit(1)
PY
}

# Build comment body from template. Args: class, pr, sha, failing.
render_template() {
    local class="$1" pr="$2" sha="$3" failing="$4"
    local tpl="$TEMPLATE_DIR/$class.md"
    [[ -f "$tpl" ]] || { echo "[chump-pr-nudge] no template for class=$class" >&2; return 1; }
    local sha_short="${sha:0:8}"
    local required_status
    if [[ -z "$failing" ]]; then required_status="green"; else required_status="failing ($failing)"; fi
    # Approximate last-commit age — kept simple; fetched from API again if template uses it.
    local last_age="recent"
    if [[ "$class" == "orphan-disarmed" ]]; then
        last_age="6h+"
    fi
    sed \
      -e "s|{{PR}}|$pr|g" \
      -e "s|{{SHA}}|$sha|g" \
      -e "s|{{SHA_SHORT}}|$sha_short|g" \
      -e "s|{{FAILING_CHECKS}}|$failing|g" \
      -e "s|{{REQUIRED_STATUS}}|$required_status|g" \
      -e "s|{{LAST_COMMIT_AGE}}|$last_age|g" \
      "$tpl"
}

# Post a comment via REST. Args: pr, body.
post_comment() {
    local pr="$1" body="$2"
    local body_json
    body_json="$(python3 -c "import json,sys; print(json.dumps({'body': sys.stdin.read()}))" <<< "$body")"
    chump_gh api "repos/$OWNER_REPO/issues/$pr/comments" -X POST \
        --input - >/dev/null 2>&1 <<< "$body_json"
}

# Record + emit ambient event. Args: pr, sha, class, posted (1|0), dry_run (1|0).
record_nudge() {
    local pr="$1" sha="$2" class="$3" posted="$4" dry_run="$5"
    mkdir -p "$LOCK_DIR"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","pr":%s,"sha":"%s","class":"%s","posted":%s,"dry_run":%s}\n' \
        "$ts" "$pr" "$sha" "$class" "$posted" "$dry_run" \
        >> "$HISTORY" 2>/dev/null || true
    [[ "$posted" -eq 1 ]] || return 0
    printf '{"ts":"%s","kind":"pr_nudged","pr":%s,"sha":"%s","class":"%s"}\n' \
        "$ts" "$pr" "$sha" "$class" \
        >> "$AMBIENT" 2>/dev/null || true
}

# Single-PR flow. Args: pr.
nudge_one() {
    local pr="$1" force="$2" dry_run="$3"
    local classify; classify="$(classify_pr "$pr")" || { echo "[chump-pr-nudge] could not classify PR #$pr" >&2; return 1; }
    if [[ -z "$classify" ]]; then
        echo "[chump-pr-nudge] PR #$pr is not stuck (state=open requires a stuck diagnosis); skipping"
        return 0
    fi
    local class sha failing
    IFS='|' read -r class sha failing <<<"$classify"
    if [[ -z "$class" ]]; then
        echo "[chump-pr-nudge] PR #$pr: no actionable diagnosis (mergeable_state may be transient); skipping"
        return 0
    fi
    if [[ "$force" -ne 1 ]] && recent_nudge_exists "$pr" "$sha" "$class"; then
        echo "[chump-pr-nudge] PR #$pr: NOTE recent nudge for (sha=$sha,class=$class) within cooldown; use --force to override"
        return 0
    fi
    local body
    body="$(render_template "$class" "$pr" "$sha" "$failing")" || return 1
    if [[ "$dry_run" -eq 1 ]]; then
        echo "--- chump-pr-nudge DRY-RUN PR #$pr class=$class ---"
        echo "$body"
        echo "--- end dry-run ---"
        record_nudge "$pr" "$sha" "$class" 0 1
    else
        if post_comment "$pr" "$body"; then
            echo "[chump-pr-nudge] posted nudge on PR #$pr (class=$class, sha=${sha:0:8})"
            record_nudge "$pr" "$sha" "$class" 1 0
        else
            echo "[chump-pr-nudge] FAILED to post comment on PR #$pr" >&2
            return 1
        fi
    fi
}

list_open_prs() {
    chump_gh api "repos/$OWNER_REPO/pulls?state=open&per_page=50" --jq '.[].number' --paginate 2>/dev/null
}

# Batch mode for a class predicate. Args: predicate-name, force, dry_run.
batch_nudge() {
    local predicate="$1" force="$2" dry_run="$3"
    local target_class
    case "$predicate" in
        all-dirty) target_class="dirty" ;;
        all-orphan) target_class="orphan-disarmed" ;;
        all-blocked-ci) target_class="blocked-ci" ;;
        all-clean) target_class="clean-not-merged" ;;
        all-base-modified) target_class="base-modified" ;;
        *) echo "unknown batch predicate: $predicate" >&2; return 2 ;;
    esac
    local prs nudged=0
    prs="$(list_open_prs)"
    for pr in $prs; do
        local classify class
        classify="$(classify_pr "$pr")" || continue
        [[ -z "$classify" ]] && continue
        IFS='|' read -r class _ _ <<<"$classify"
        [[ "$class" == "$target_class" ]] || continue
        nudge_one "$pr" "$force" "$dry_run" && nudged=$((nudged + 1))
    done
    echo "[chump-pr-nudge] batch $predicate: $nudged PR(s) processed"
}

print_stats() {
    [[ -f "$HISTORY" ]] || { echo "no history yet"; exit 0; }
    python3 - "$HISTORY" <<'PY'
import json, sys, collections
path = sys.argv[1]
classes = collections.Counter()
posted = 0; dry = 0
with open(path) as f:
    for line in f:
        try: rec = json.loads(line)
        except Exception: continue
        classes[rec.get('class','?')] += 1
        if rec.get('posted'): posted += 1
        if rec.get('dry_run'): dry += 1
print(f"total entries: {sum(classes.values())} (posted={posted} dry-run={dry})")
print("per-class:")
for k, v in classes.most_common():
    print(f"  {k:24s} {v}")
PY
}

# ── Argument parse ────────────────────────────────────────────────────────────
FORCE=0
DRY_RUN=0
MODE=""
PR=""
BATCH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage ;;
        --dry-run) DRY_RUN=1; shift ;;
        --force) FORCE=1; shift ;;
        --stats) MODE="stats"; shift ;;
        --all-dirty|--all-orphan|--all-blocked-ci|--all-clean|--all-base-modified)
            MODE="batch"; BATCH="${1#--}"; shift ;;
        [0-9]*) MODE="single"; PR="$1"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[[ -n "$OWNER_REPO" ]] || { echo "[chump-pr-nudge] could not resolve owner/repo from git remote" >&2; exit 2; }

case "$MODE" in
    single) nudge_one "$PR" "$FORCE" "$DRY_RUN" ;;
    batch)  batch_nudge "$BATCH" "$FORCE" "$DRY_RUN" ;;
    stats)  print_stats ;;
    *)      usage ;;
esac
