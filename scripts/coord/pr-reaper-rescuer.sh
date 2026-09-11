#!/usr/bin/env bash
# pr-reaper-rescuer.sh — RESILIENT-1108: revive good PRs a reaper wrongly closed.
#
# THE PROBLEM (2026-09-10/11 incident): the fleet has three destructive reapers —
#   * stale-pr-reaper.sh (INFRA-1410 PR-stuck SLO + auto-respawn)
#   * rot-reaper.sh       (RESILIENT-311 no-abandon janitor)
#   * pr-failure-auto-rescue.sh terminal-dispose (INFRA-3542)
# each of which closes a PR whose *required* check sat RED past an SLO. That red
# is often a FIXABLE cause — a 22-min-late parity gate, a flake that exhausted
# its rerun budget, a cancelled CI run — i.e. the PR is GREEN UNDERNEATH. The
# gap re-queues, but the PR (with its history + review) dies and the work churns
# (#4589 #4598 #4601 #4615 #4618). classify-blocked-pr.py (#4606) taught the
# reapers to *spare* recoverable BLOCKED PRs, but nothing REVIVES the ones
# already closed. This organ is that missing counterweight.
#
# WHY NOT the existing rescue scripts:
#   * pr-rescue-false-close.sh (INFRA-1406) — manual, single-PR, unbounded, and
#     does no green-underneath classification (reopens anything not CONFLICTING).
#   * closed-pr-watchdog.sh — scans closed-not-merged PRs but reopens (default
#     OFF) with no reaper-close detection and no green-underneath gate.
#   * pr-failure-auto-rescue.sh — a FIXER that can CLOSE; it never reopens.
# None of them: (a) target reaper-closed PRs specifically, (b) reuse the
# green-underneath classifier, (c) are BOUNDED so they don't fight the reaper
# forever. This organ does all three.
#
# DETECT   → closed-unmerged PRs whose close was a reaper (close comment cites a
#            reaper ID, or a reaper label is present, or ambient recorded a reap)
#            and NOT a deliberate human close.
# CLASSIFY → rescue-eligible iff the gap is still open/in-flight (work still
#            wanted) AND the last red was a FIXABLE cause (green-underneath),
#            reusing scripts/ops/lib/classify-blocked-pr.py. Genuinely-dead PRs
#            (hard test failure, real merge conflict, rot-reaped/retired label,
#            superseded gap) are LEFT ALONE.
# RESCUE   → reopen; if BEHIND, rebase onto current main; re-arm auto-merge so
#            the lander (RESILIENT-288) carries it home.
# BOUND    → rescue a given PR at most CHUMP_PR_RESCUE_MAX times (default 2),
#            then ESCALATE to the operator instead of resurrecting again. This
#            is the load-bearing safety: without it the rescuer and the reaper
#            ping-pong the same PR forever.
#
# Emits (registered in docs/observability/EVENT_REGISTRY.yaml):
#   kind=pr_rescued            {pr, branch, gap, verdict, attempt, action}
#   kind=pr_rescue_escalated   {pr, branch, gap, attempts, reason}
#
# Usage:
#   bash scripts/coord/pr-reaper-rescuer.sh                 # one scan (live)
#   bash scripts/coord/pr-reaper-rescuer.sh --dry-run       # scan, act on nothing
#   bash scripts/coord/pr-reaper-rescuer.sh --loop          # daemon (interval)
#   bash scripts/coord/pr-reaper-rescuer.sh --decide ...    # pure verdict (tests)
#
# Env:
#   CHUMP_PR_RESCUE_MAX          max rescues per PR before escalate (default 2)
#   CHUMP_PR_RESCUE_LOOKBACK_H   how far back to scan closed PRs (default 48)
#   CHUMP_PR_RESCUE_INTERVAL_S   --loop sleep between scans (default 900)
#   CHUMP_PR_RESCUE_REPO         owner/repo (default repairman29/chump)
#   CHUMP_PR_RESCUER=0           disable entirely
#
# Exit: always 0 in scan mode (best-effort janitor; never blocks a caller).

set -uo pipefail

[[ "${CHUMP_PR_RESCUER:-1}" == "0" ]] && exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
CLASSIFY="$REPO_ROOT/scripts/ops/lib/classify-blocked-pr.py"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
ATTEMPTS_LOG="${CHUMP_PR_RESCUE_LOG:-$REPO_ROOT/.chump-locks/pr-reaper-rescuer-attempts.jsonl}"
REPO="${CHUMP_PR_RESCUE_REPO:-repairman29/chump}"
MAX="${CHUMP_PR_RESCUE_MAX:-2}"
LOOKBACK_H="${CHUMP_PR_RESCUE_LOOKBACK_H:-48}"
INTERVAL_S="${CHUMP_PR_RESCUE_INTERVAL_S:-900}"

DRY_RUN=0
LOOP=0

# Reaper signatures in a close comment (any match => reaper-closed, not human).
REAPER_SIGNATURES='stale-pr-reaper|rot-reaper|INFRA-1410|RESILIENT-311|INFRA-3542|no-abandon janitor|pr-failure-auto-rescue'
# Labels a reaper stamps to mean "deliberately dead — do NOT revive" (a real
# merge conflict / stale-conflicting; the conflict-resolution-consumer already
# tried and could not). Honoring these is what averts the reap/revive deadlock
# that motivated the rot-reaped label in the first place (RESILIENT-311).
DEAD_LABELS='rot-reaped|retired'

say() { echo "[pr-reaper-rescuer $(date -u +%H:%M:%S)] $*" >&2; }

emit() {
    # The emit helper writes the kind as a runtime variable, so the two kinds
    # this organ produces are not grep-scannable as `"kind":"X"` literals by the
    # event-registry coverage scanner. Anchor them here so the register↔emit
    # audit resolves in both directions (per EVENT_REGISTRY_FORMAT.md).
    # scanner-anchor: "kind":"pr_rescued"
    # scanner-anchor: "kind":"pr_rescue_escalated"
    # emit KIND JSON-FIELDS...   (fields already formatted as "k":v,"k2":v2)
    local kind="$1"; shift
    local fields="$*"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ $DRY_RUN -eq 1 ]]; then
        say "[dry] would emit kind=$kind $fields"
        return 0
    fi
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s","source":"pr-reaper-rescuer",%s}\n' \
        "$ts" "$kind" "$fields" >> "$AMBIENT" 2>/dev/null || true
}

# ── Bound bookkeeping ────────────────────────────────────────────────────────
# Count prior rescues of a PR from the attempts log (one JSON line per rescue).
count_attempts() {
    local pr="$1"
    [[ -f "$ATTEMPTS_LOG" ]] || { echo 0; return; }
    awk -v pr="$pr" 'index($0,"\"pr\":"pr",")>0 || index($0,"\"pr\":"pr"}")>0 {n++} END{print n+0}' "$ATTEMPTS_LOG"
}

record_attempt() {
    local pr="$1"; local branch="$2"; local gap="$3"; local action="$4"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$ATTEMPTS_LOG")" 2>/dev/null || true
    printf '{"ts":"%s","pr":%s,"branch":"%s","gap":"%s","action":"%s"}\n' \
        "$ts" "$pr" "$branch" "$gap" "$action" >> "$ATTEMPTS_LOG" 2>/dev/null || true
}

# ── Pure decision (Receipt Law surface) ──────────────────────────────────────
# Emits exactly one verdict token given fully-resolved inputs. No I/O, no gh.
#   RESCUE                 reaper-closed, green-underneath, gap wanted, under cap
#   ESCALATE               would rescue but already at/over the rescue cap
#   SKIP_ALREADY_MERGED    state==MERGED (superseded / landed)
#   SKIP_ALREADY_OPEN      state==OPEN (nothing to reopen; lander owns it)
#   SKIP_HUMAN_CLOSED      closed, but NOT by a reaper (respect the human)
#   SKIP_GAP_NOT_WANTED    gap done/closed/missing (work no longer wanted)
#   SKIP_DEAD_CONFLICT     real merge conflict or dead-label (needs a human)
#   SKIP_HARD_FAIL         a genuine required-check failure (not flake/cancel)
decide_rescue() {
    local state="$1" closed_by_reaper="$2" mergeable="$3" classify="$4" \
          cancelled_only="$5" dead_label="$6" gap_status="$7" attempts="$8" max="$9"

    state="$(echo "$state" | tr '[:lower:]' '[:upper:]')"
    mergeable="$(echo "$mergeable" | tr '[:lower:]' '[:upper:]')"
    gap_status="$(echo "$gap_status" | tr '[:upper:]' '[:lower:]')"

    [[ "$state" == "MERGED" ]] && { echo "SKIP_ALREADY_MERGED"; return; }
    [[ "$state" == "OPEN"   ]] && { echo "SKIP_ALREADY_OPEN";   return; }
    [[ "$closed_by_reaper" != "1" ]] && { echo "SKIP_HUMAN_CLOSED"; return; }

    # Genuinely-dead markers first — never revive these regardless of anything
    # else (they mean a human/consumer already judged the branch unmergeable).
    [[ "$dead_label" == "1" ]] && { echo "SKIP_DEAD_CONFLICT"; return; }
    [[ "$mergeable" == "CONFLICTING" || "$classify" == "conflict" ]] && { echo "SKIP_DEAD_CONFLICT"; return; }

    # Work still wanted? Only BLOCK on a POSITIVELY-superseded gap — one we can
    # tie to a done/closed record (e.g. #4601, whose gap RESILIENT-001 already
    # landed via the merged re-drive #4627). An unknown/unparseable gap does NOT
    # block: a reaper-closed, green-underneath branch is itself evidence the work
    # was in-flight and wanted, and many legit fix-PRs (e.g. "completes PR #NNNN")
    # carry no gap id at all. The bound below stops any mistaken revival cold.
    case "$gap_status" in
        done|closed|merged|superseded|cancelled|shipped|resolved)
            echo "SKIP_GAP_NOT_WANTED"; return ;;
        *) : ;;  # open|in_progress|reserved|claimed|unknown|"" → still wanted
    esac

    # Green-underneath gate. hard_fail is dead UNLESS the only failing checks
    # were CANCELLED (a CI-cancel is a fixable cause, per the incident).
    if [[ "$classify" == "hard_fail" && "$cancelled_only" != "1" ]]; then
        echo "SKIP_HARD_FAIL"; return
    fi

    # Recoverable: pending / flake_exhausted / blocked_no_failure / cancel-only.
    # Enforce the bound LAST so the cap only bites work we would actually rescue.
    if [[ "$attempts" -ge "$max" ]]; then
        echo "ESCALATE"; return
    fi
    echo "RESCUE"
}

# ── --decide mode: exercise decide_rescue from the CLI (tests) ───────────────
if [[ "${1:-}" == "--decide" ]]; then
    shift
    d_state="CLOSED"; d_reaper="1"; d_mergeable="MERGEABLE"; d_classify="blocked_no_failure"
    d_cancelled="0"; d_deadlabel="0"; d_gap="open"; d_attempts="0"; d_max="$MAX"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --state)          d_state="$2"; shift 2 ;;
            --closed-by-reaper) d_reaper="$2"; shift 2 ;;
            --mergeable)      d_mergeable="$2"; shift 2 ;;
            --classify)       d_classify="$2"; shift 2 ;;
            --cancelled-only) d_cancelled="$2"; shift 2 ;;
            --dead-label)     d_deadlabel="$2"; shift 2 ;;
            --gap-status)     d_gap="$2"; shift 2 ;;
            --attempts)       d_attempts="$2"; shift 2 ;;
            --max)            d_max="$2"; shift 2 ;;
            *) echo "decide: unknown flag $1" >&2; exit 2 ;;
        esac
    done
    decide_rescue "$d_state" "$d_reaper" "$d_mergeable" "$d_classify" \
                  "$d_cancelled" "$d_deadlabel" "$d_gap" "$d_attempts" "$d_max"
    exit 0
fi

# ── Live helpers ─────────────────────────────────────────────────────────────
# All read paths prefer REST (core bucket) over GraphQL per the cache-first rule.

gap_status_of() {
    # Print the gap's status (open|in_progress|done|closed|"") from state.db.
    local gap="$1"
    [[ -z "$gap" ]] && return 0
    local chump="${HOME}/.cargo/bin/chump"
    command -v "$chump" >/dev/null 2>&1 || chump="chump"
    command -v "$chump" >/dev/null 2>&1 || return 0
    CHUMP_REPO="$REPO_ROOT" CHUMP_BINARY_STALENESS_CHECK=0 \
        "$chump" gap show "$gap" 2>/dev/null \
        | awk '/^[[:space:]]*status:/{print $2; exit}'
}

# cancelled_only ROLLUP_JSON — 1 iff every failing completed check is CANCELLED.
cancelled_only_of() {
    python3 -c '
import json,sys
try: rows=json.loads(sys.argv[1] or "[]")
except Exception: print("0"); sys.exit()
if isinstance(rows,dict): rows=rows.get("statusCheckRollup") or []
FAIL={"FAILURE","TIMED_OUT","STARTUP_FAILURE","ACTION_REQUIRED","STALE","ERROR"}
any_fail=False; only_cancel=True
for c in rows:
    if not isinstance(c,dict): continue
    if (c.get("status") or "").upper()=="COMPLETED":
        concl=(c.get("conclusion") or "").upper()
        if concl=="CANCELLED": any_fail=True
        elif concl in FAIL: any_fail=True; only_cancel=False
print("1" if (any_fail and only_cancel) else "0")
' "$1" 2>/dev/null || echo "0"
}

# ── Scan one closed PR and act ───────────────────────────────────────────────
process_pr() {
    local pr="$1"
    local meta
    meta="$(gh pr view "$pr" --repo "$REPO" \
        --json state,headRefName,mergeable,mergeStateStatus,labels,statusCheckRollup,title 2>/dev/null)" \
        || { say "PR #$pr: gh view failed"; return 0; }

    local state branch mergeable merge_state labels_csv title
    state="$(echo "$meta"     | python3 -c 'import json,sys;print(json.load(sys.stdin).get("state",""))')"
    branch="$(echo "$meta"    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("headRefName",""))')"
    mergeable="$(echo "$meta" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("mergeable",""))')"
    merge_state="$(echo "$meta"| python3 -c 'import json,sys;print(json.load(sys.stdin).get("mergeStateStatus",""))')"
    labels_csv="$(echo "$meta"| python3 -c 'import json,sys;print(",".join(l.get("name","") for l in (json.load(sys.stdin).get("labels") or [])))')"
    title="$(echo "$meta"     | python3 -c 'import json,sys;print((json.load(sys.stdin).get("title") or "")[:160])')"

    [[ "$state" != "CLOSED" ]] && return 0

    # Gap id: from the branch (chump/infra-1240-claim -> INFRA-1240) OR, when the
    # branch is a bare slug (durability-gauge, cockpit-current-operating-state),
    # from the PR TITLE (many chump branches carry the gap id only in the title,
    # e.g. "RESILIENT-1088: light cockpit ..."). "" means the gap gate treats it
    # as not-wanted (fail-safe: don't resurrect work we can't tie to a gap).
    local gap_re='(infra|credible|fleet|mission|meta|eval|zero-waste|resilient|effective)-[0-9]+'
    local gap_raw gap
    gap_raw="$(echo "$branch" | grep -oiE "$gap_re" | head -1 || true)"
    [[ -z "$gap_raw" ]] && gap_raw="$(echo "$title" | grep -oiE "$gap_re" | head -1 || true)"
    gap="$(echo "$gap_raw" | tr '[:lower:]' '[:upper:]')"

    # Reaper-close detection: label OR close-comment signature.
    local dead_label=0 closed_by_reaper=0
    echo ",$labels_csv," | grep -qiE ",($DEAD_LABELS)," && { dead_label=1; closed_by_reaper=1; }
    if [[ $closed_by_reaper -eq 0 ]]; then
        local comments
        comments="$(gh pr view "$pr" --repo "$REPO" --json comments \
            --jq '.comments[-6:][].body' 2>/dev/null || true)"
        echo "$comments" | grep -qiE "$REAPER_SIGNATURES" && closed_by_reaper=1
    fi

    # Green-underneath classification (reuse #4606's classifier).
    local rollup classify cancelled_only
    rollup="$(echo "$meta" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin).get("statusCheckRollup") or []))')"
    if [[ -x "$CLASSIFY" || -f "$CLASSIFY" ]]; then
        classify="$(printf '%s' "$rollup" | python3 "$CLASSIFY" --rollup-file - --mergeable "$mergeable" 2>/dev/null || echo "blocked_no_failure")"
    else
        classify="blocked_no_failure"
    fi
    cancelled_only="$(cancelled_only_of "$rollup")"

    local gap_status attempts verdict
    gap_status="$(gap_status_of "$gap")"
    attempts="$(count_attempts "$pr")"

    verdict="$(decide_rescue "$state" "$closed_by_reaper" "$mergeable" \
        "$classify" "$cancelled_only" "$dead_label" "${gap_status:-}" "$attempts" "$MAX")"

    say "PR #$pr [$branch] gap=${gap:-none} state=$state merge=$mergeable/$merge_state classify=$classify cancel_only=$cancelled_only reaper=$closed_by_reaper attempts=$attempts → $verdict"

    case "$verdict" in
        RESCUE)
            if [[ $DRY_RUN -eq 1 ]]; then
                say "  [dry] would reopen + rebase-if-behind + re-arm PR #$pr"
                return 0
            fi
            if ! gh pr reopen "$pr" --repo "$REPO" >/dev/null 2>&1; then
                say "  reopen failed for #$pr (branch may be gone) — leaving for follow-up"
                emit pr_rescue_escalated "\"pr\":$pr,\"branch\":\"$branch\",\"gap\":\"$gap\",\"attempts\":$attempts,\"reason\":\"reopen_failed\""
                return 0
            fi
            local action="reopened"
            if [[ "$merge_state" == "BEHIND" ]]; then
                if gh pr update-branch "$pr" --repo "$REPO" --rebase >/dev/null 2>&1; then
                    action="reopened_rebased"
                fi
            fi
            # Re-arm auto-merge so the lander (RESILIENT-288) carries it home.
            gh pr merge "$pr" --repo "$REPO" --auto --squash >/dev/null 2>&1 || true
            gh pr comment "$pr" --repo "$REPO" --body \
"Rescued by pr-reaper-rescuer (RESILIENT-1108): this PR was closed by a reaper on a *fixable* red (classify=\`$classify\`), but the gap is still wanted and the branch is green-underneath. Reopened$([ "$action" = reopened_rebased ] && echo ' + rebased onto current main') and re-armed for auto-merge. Rescue attempt $((attempts+1))/$MAX — after $MAX this PR escalates to the operator instead of resurrecting again." >/dev/null 2>&1 || true
            record_attempt "$pr" "$branch" "$gap" "$action"
            emit pr_rescued "\"pr\":$pr,\"branch\":\"$branch\",\"gap\":\"$gap\",\"verdict\":\"$classify\",\"attempt\":$((attempts+1)),\"action\":\"$action\""
            say "  RESCUED #$pr ($action)"
            ;;
        ESCALATE)
            if [[ $DRY_RUN -eq 1 ]]; then
                say "  [dry] would escalate PR #$pr (attempts=$attempts >= max=$MAX)"
                return 0
            fi
            emit pr_rescue_escalated "\"pr\":$pr,\"branch\":\"$branch\",\"gap\":\"$gap\",\"attempts\":$attempts,\"reason\":\"rescue_cap_reached\""
            if [[ -f "$SCRIPT_DIR/lib/notify-operator.sh" ]]; then
                # shellcheck source=lib/notify-operator.sh
                source "$SCRIPT_DIR/lib/notify-operator.sh"
                notify_operator "$(printf '🛟 **PR #%s hit the rescue cap (%s)** — not resurrecting again.\n\nA reaper keeps closing this PR and pr-reaper-rescuer keeps reviving it (%s attempts). That ping-pong means it needs a human, not another automatic redo.\nBranch: `%s`  Gap: %s\n\nhttps://github.com/%s/pull/%s' \
                    "$pr" "$MAX" "$attempts" "$branch" "${gap:-<none>}" "$REPO" "$pr")" 2>/dev/null || true
            fi
            say "  ESCALATED #$pr (rescue cap $MAX reached)"
            ;;
        *)
            : # every SKIP_* verdict: intentionally leave the PR alone.
            ;;
    esac
}

# ── Scan: closed-unmerged PRs within the lookback window (REST) ──────────────
run_scan() {
    command -v gh >/dev/null 2>&1     || { say "gh not found, skipping"; return 0; }
    command -v python3 >/dev/null 2>&1 || { say "python3 not found, skipping"; return 0; }

    say "scanning closed-unmerged PRs in $REPO (lookback ${LOOKBACK_H}h, max=$MAX)…"
    local cutoff; cutoff=$(( $(date -u +%s) - LOOKBACK_H * 3600 ))
    local closed_json
    closed_json="$(gh api "repos/$REPO/pulls?state=closed&per_page=100&sort=updated&direction=desc" 2>/dev/null || echo '[]')"

    local prs
    prs="$(printf '%s' "$closed_json" | python3 -c "
import json,sys,datetime
cutoff=$cutoff
try: data=json.load(sys.stdin)
except Exception: data=[]
for pr in data:
    if pr.get('merged_at') is not None: continue      # merged correctly
    if pr.get('state')!='closed': continue
    ts=pr.get('updated_at') or pr.get('closed_at') or ''
    if ts:
        try:
            if int(datetime.datetime.fromisoformat(ts.replace('Z','+00:00')).timestamp())<cutoff: continue
        except Exception: pass
    print(pr['number'])
" 2>/dev/null || true)"

    local n=0
    for pr in $prs; do
        [[ -z "$pr" ]] && continue
        process_pr "$pr"
        n=$((n+1))
    done
    say "scan complete: examined $n closed PR(s)"
}

# ── Arg parse (scan/loop/dry-run) ────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --loop)    LOOP=1 ;;
        --once)    LOOP=0 ;;
        -h|--help) sed -n '2,60p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

if [[ $LOOP -eq 1 ]]; then
    say "loop mode (interval ${INTERVAL_S}s)…"
    while true; do
        run_scan
        sleep "$INTERVAL_S"
    done
else
    run_scan
fi
exit 0
