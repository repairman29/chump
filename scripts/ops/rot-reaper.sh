#!/usr/bin/env bash
# rot-reaper.sh — drain genuinely-CONFLICTING PRs so the fleet self-heals.
#
# WHY (operator, 2026-08-14 deadlock): the back-pressure controller
# (scripts/ops/back-pressure-controller.sh) HALTS production when the "stuck
# pile" (open PRs that are BLOCKED or DIRTY) hits HALT_AT (6). It RESUMES when
# the pile drains below RESUME_AT (3). The armed-rebaser
# (scripts/coord/armed-pr-rebaser.sh) drains the pile by rebasing PRs that are
# BEHIND — but it CANNOT resolve a real merge CONFLICT. So when the jam is
# mostly CONFLICTING PRs, the rebaser drains the pile partway (to 4–5), it
# lands in the 3–6 hysteresis dead-zone, and the fleet stays HALTED forever
# with no auto-recovery. That is exactly what deadlocked the fleet for hours.
#
# This organ is the missing drain: it CLOSES open PRs that are truly
# CONFLICTING and old enough that they are never going to auto-rebase, and
# RE-QUEUES their gap so the fleet re-does the work cleanly on fresh main. A
# CONFLICTING PR represents work that must be redone anyway (the branch and
# main diverged in the same lines); reaping it loses nothing and unblocks the
# breaker.
#
# What it does, per open PR authored by the fleet:
#   1. Skip filing PRs ("chore(gaps): file/reserve …") — never self-close.
#   2. Only act when mergeable == "CONFLICTING". BLOCKED-but-MERGEABLE PRs are
#      NOT touched — those just need CI/approval, not reaping (the pr-lander /
#      ci-flake-rerun organs handle them).
#   3. Age gate: only close PRs older than MIN_AGE_HOURS (default 4h). A fresh
#      conflict may still be actively rebased by its owner; never reap it.
#   4. Re-queue each cited gap: if its status is not already `open` and not
#      `done`, `chump gap set --status open` + an audit note. If the gap is
#      already `done` (a stale DUPLICATE PR whose work landed elsewhere), do
#      NOT try to reopen it — the recycled-ID guard blocks that and it would
#      be wrong anyway; just close the PR.
#   5. Close the PR with an explanatory comment.
#
# Idempotent (a PR it closes leaves the open set; the gap note is tagged),
# logged, and dry-run-able. Safe to run on a timer.
#
# Usage:
#   ./scripts/ops/rot-reaper.sh              # live run
#   ./scripts/ops/rot-reaper.sh --dry-run    # print what would happen, no changes
#
# Environment:
#   CHUMP_ROT_REAPER_MIN_AGE_HOURS  min PR age (hours) before it can be reaped
#                                   (default 4). Excludes fresh conflicts.
#   CHUMP_ROT_REAPER_MAX            safety cap: max PRs to close per run
#                                   (default 10). Prevents a runaway mass-close.
#   CHUMP_ROT_REAPER_PR_JSON        TEST HOOK: path to a JSON file used INSTEAD
#                                   of `gh pr list`. Lets CI exercise the
#                                   selection logic without a live GitHub.
#   REMOTE / BASE                   git remote / base branch (default origin/main)
set -uo pipefail

# ── shared reaper instrumentation (heartbeat + reaper_run event + log rotate) ─
# shellcheck source=../lib/reaper-instrumentation.sh
source "$(dirname "$0")/../lib/reaper-instrumentation.sh"
reaper_setup rot
reaper_rotate_log /tmp/chump-rot-reaper.out.log
reaper_rotate_log /tmp/chump-rot-reaper.err.log

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

MIN_AGE_HOURS="${CHUMP_ROT_REAPER_MIN_AGE_HOURS:-4}"
MAX_CLOSE="${CHUMP_ROT_REAPER_MAX:-10}"
REMOTE="${REMOTE:-origin}"
BASE="${BASE:-main}"

red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
warn()  { printf '\033[0;33m  WARN: %s\033[0m\n' "$*"; }
dry()   { printf '  [dry-run] %s\n' "$*"; }

green "=== rot-reaper (conflicting-PR drain; min-age=${MIN_AGE_HOURS}h, max=${MAX_CLOSE}) ==="
[[ $DRY_RUN -eq 1 ]] && info "Dry-run mode — no PRs will be closed and no gaps re-queued."

ME="$(gh api user --jq .login 2>/dev/null || echo repairman29)"

# ── source of candidate PRs ───────────────────────────────────────────────────
# TEST HOOK: CHUMP_ROT_REAPER_PR_JSON supplies a fixture so CI can exercise the
# selection logic (age gate + CONFLICTING filter) without a live GitHub.
PR_JSON=""
if [[ -n "${CHUMP_ROT_REAPER_PR_JSON:-}" ]]; then
    PR_JSON="$(cat "$CHUMP_ROT_REAPER_PR_JSON" 2>/dev/null || echo '[]')"
    info "Using fixture PR list from \$CHUMP_ROT_REAPER_PR_JSON."
else
    PR_JSON="$(gh pr list --author "$ME" --state open --limit 100 \
        --json number,title,mergeStateStatus,mergeable,createdAt,headRefName \
        2>/dev/null || echo '[]')"
fi

# Rows as TSV: number \t mergeable \t createdAt \t title
ROWS="$(printf '%s' "$PR_JSON" | python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in rows:
    num   = r.get("number", "")
    mrg   = r.get("mergeable", "")
    made  = r.get("createdAt", "")
    title = (r.get("title") or "").replace("\t", " ").replace("\n", " ")
    print(f"{num}\t{mrg}\t{made}\t{title}")
' 2>/dev/null || true)"

# age_hours ISO8601 — whole hours since createdAt (python, bash-free of `date -d`).
age_hours() {
    python3 -c '
import sys
from datetime import datetime, timezone
try:
    dt = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
    print(int((datetime.now(timezone.utc) - dt).total_seconds() // 3600))
except Exception:
    print(-1)
' "$1" 2>/dev/null || echo -1
}

is_filing_pr_title() {
    case "$1" in
        "chore(gaps): file "*|"chore(gaps): reserve "*) return 0 ;;
        *) return 1 ;;
    esac
}

CLOSED=0
REQUEUED=0
SKIPPED=0

if [[ -z "$ROWS" ]]; then
    info "No open PRs found — nothing to reap."
    reaper_finish ok '{"closed":0,"requeued":0,"skipped":0}'
    exit 0
fi

while IFS=$'\t' read -r PR_NUM MERGEABLE CREATED TITLE; do
    [[ -z "$PR_NUM" ]] && continue

    # (2) Only genuinely CONFLICTING PRs. BLOCKED/MERGEABLE ones need CI or
    # approval, not reaping — leave them for the pr-lander / ci-flake organs.
    if [[ "$MERGEABLE" != "CONFLICTING" ]]; then
        continue
    fi

    # (1) Never self-close a gap-filing PR.
    if is_filing_pr_title "$TITLE"; then
        info "PR #$PR_NUM — filing PR, skipping."
        continue
    fi

    # (3) Age gate — never reap a fresh conflict (owner may be mid-rebase).
    AGE="$(age_hours "$CREATED")"
    if [[ "$AGE" -lt 0 ]]; then
        warn "PR #$PR_NUM — could not parse createdAt ($CREATED); skipping (fail-safe)."
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    if [[ "$AGE" -lt "$MIN_AGE_HOURS" ]]; then
        info "PR #$PR_NUM — CONFLICTING but only ${AGE}h old (< ${MIN_AGE_HOURS}h); leaving for the owner/rebaser."
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    if [[ "$CLOSED" -ge "$MAX_CLOSE" ]]; then
        warn "Reached MAX_CLOSE=$MAX_CLOSE this run; deferring the rest to the next tick."
        break
    fi

    red "PR #$PR_NUM — CONFLICTING, ${AGE}h old → REAP"
    info "  title: $TITLE"

    # Cited gap IDs from the title (and, when live, the branch commits).
    GAP_IDS="$(printf '%s\n' "$TITLE" | grep -oE '\b[A-Z]+-[0-9]+\b' | sort -u || true)"

    # (4) Re-queue each cited gap unless it is already open or already done.
    for GID in $GAP_IDS; do
        [[ -z "$GID" ]] && continue
        if ! command -v chump >/dev/null 2>&1; then
            info "  (chump CLI unavailable — skipping re-queue of $GID)"
            continue
        fi
        CUR="$(chump gap show "$GID" 2>/dev/null || true)"
        [[ -z "$CUR" ]] && { info "  $GID not found in gap store — nothing to re-queue."; continue; }
        STATUS="$(awk '/^[[:space:]]*status:/{sub(/^[[:space:]]*status:[[:space:]]*/,""); print; exit}' <<<"$CUR")"
        if [[ "$STATUS" == "done" ]]; then
            # Stale DUPLICATE PR: the work already landed elsewhere. Do NOT
            # reopen — the recycled-ID guard rejects it and it would be wrong.
            info "  $GID already done — stale duplicate PR; closing without re-queue."
            continue
        fi
        NOTE="rot-reaper: PR #${PR_NUM} auto-closed (CONFLICTING, ${AGE}h) $(date -u +%Y-%m-%d); re-attempt on fresh main."
        if [[ $DRY_RUN -eq 1 ]]; then
            dry "would re-queue $GID (status=$STATUS) + note"
            continue
        fi
        if [[ "$STATUS" != "open" ]]; then
            chump gap set "$GID" --status open >/dev/null 2>&1 \
                || warn "chump gap set $GID --status open failed"
        fi
        chump gap set "$GID" --add-note "$NOTE" >/dev/null 2>&1 \
            || warn "chump gap set $GID --add-note failed"
        info "  re-queued $GID (was $STATUS)"
        REQUEUED=$((REQUEUED + 1))
    done

    CLOSE_MSG="Auto-closing (rot-reaper): this PR is **CONFLICTING** with \`${BASE}\` and is ${AGE}h old. The armed-rebaser only rebases *behind* PRs — it cannot resolve a real merge conflict — so this branch would sit unmerged indefinitely and keep the production back-pressure breaker halted. The cited gap(s) have been re-queued to be re-done cleanly on fresh \`${BASE}\`. Nothing is lost: a conflicting branch must be redone anyway. (RESILIENT-324)"

    if [[ $DRY_RUN -eq 1 ]]; then
        dry "gh pr close $PR_NUM --comment \"…\""
        CLOSED=$((CLOSED + 1))
        continue
    fi

    if gh pr close "$PR_NUM" --comment "$CLOSE_MSG" 2>/dev/null; then
        green "  closed PR #$PR_NUM"
        CLOSED=$((CLOSED + 1))
    else
        warn "gh pr close $PR_NUM failed."
    fi
done <<< "$ROWS"

green "=== rot-reaper done: closed=$CLOSED requeued=$REQUEUED skipped=$SKIPPED ==="
reaper_finish ok "{\"closed\":$CLOSED,\"requeued\":$REQUEUED,\"skipped\":$SKIPPED}"
