#!/usr/bin/env bash
# closer-pr-batcher.sh — INFRA-194 (2026-05-01)
#
# Periodic agent that catches gap-status drifts where `.chump/state.db`
# says status:done but `docs/gaps.yaml` (or per-file equivalent post
# INFRA-188) hasn't been updated to match. INFRA-154 (auto-flip on ship)
# handles the steady-state case — when bot-merge.sh successfully ships
# a PR, the gap closure lands atomically with the implementation. But
# the registry still picks up drift from:
#
#   1. Drive-by closures (operator runs `chump gap set <ID> --status
#      done` directly, no PR)
#   2. Cold Water sweep that flips multiple gaps at once but doesn't
#      regenerate YAML
#   3. Manual ship that bypasses bot-merge.sh
#   4. INFRA-154's auto-flip path failed silently (e.g. chump binary
#      stale; gap not yet imported into state.db)
#
# This script regenerates docs/gaps.yaml from state.db. If the diff is
# non-empty, it opens a PR titled "chore(close): batch yaml regen for N
# gap closures" and ships via bot-merge.sh. If the diff is empty (steady
# state), it exits 0 with no PR.
#
# Designed to run periodically (cron / launchd / overnight scheduler).
# Default cadence: every 4 hours. Set via the install-launchd / cron
# config; the script itself takes no time argument.
#
# Usage:
#   scripts/ops/closer-pr-batcher.sh                     # dry-run-then-ship
#   scripts/ops/closer-pr-batcher.sh --dry-run           # diff only, no PR
#   scripts/ops/closer-pr-batcher.sh --max-gaps N        # cap PR size (default 25)
#   scripts/ops/closer-pr-batcher.sh --skip-bot-merge    # write commit + push, no PR
#
# Env:
#   CHUMP_BATCHER=0     bypass — exit 0 immediately (for tests)
#
# Exit codes:
#   0  no diff (steady state) OR PR shipped
#   1  diff has unexpected changes (e.g. preamble drift) — operator must review
#   2  ship failed (bot-merge.sh / git push)
#   3  usage / preflight error

set -euo pipefail

if [[ "${CHUMP_BATCHER:-1}" == "0" ]]; then
    echo "[batcher] CHUMP_BATCHER=0 — bypass"
    exit 0
fi

DRY_RUN=0
MAX_GAPS=25
SKIP_BOT_MERGE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)         DRY_RUN=1; shift ;;
        --max-gaps)        MAX_GAPS="$2"; shift 2 ;;
        --skip-bot-merge)  SKIP_BOT_MERGE=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 3 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

say()  { printf '\033[1;36m[batcher]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[batcher]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[batcher]\033[0m %s\n' "$*" >&2; exit "${2:-3}"; }

# ── Preflight ───────────────────────────────────────────────────────────────
command -v chump >/dev/null 2>&1 || die "chump CLI not on PATH" 3
[[ -f .chump/state.db ]] || die ".chump/state.db missing — nothing to dump" 3

# Working tree must be clean — the batcher is supposed to make ONE clean diff.
if ! git diff --quiet docs/gaps.yaml 2>/dev/null; then
    die "docs/gaps.yaml has uncommitted changes — refusing to overwrite. Commit or stash first." 3
fi

# Operator must be on main (or a branch that's clean to push from).
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo '')"
if [[ -z "$BRANCH" ]]; then
    die "not on a branch — cannot push" 3
fi

# ── Regenerate ───────────────────────────────────────────────────────────────
say "Regenerating docs/gaps.yaml from .chump/state.db…"
chump gap dump --out docs/gaps.yaml >/dev/null 2>&1 \
    || die "chump gap dump failed — check binary freshness" 3

# Diff size + classification
DIFF_LINES=$(git diff --numstat docs/gaps.yaml 2>/dev/null \
    | awk '{print $1+$2}' | head -n1 || echo 0)
if [[ "${DIFF_LINES:-0}" == "0" ]] || [[ -z "$DIFF_LINES" ]]; then
    say "No diff — registry is in steady state. Exiting clean."
    exit 0
fi

# Count which gap IDs changed status
CHANGED_GAPS=$(git diff docs/gaps.yaml \
    | grep -E '^\+\s+status:\s+done' \
    | wc -l \
    | tr -d ' ')

if [[ "${CHANGED_GAPS:-0}" -eq 0 ]]; then
    warn "Diff exists but no status:done flips — this looks like preamble or content drift, not closures."
    warn "Refusing to ship; operator should review the diff manually:"
    warn "  git diff docs/gaps.yaml"
    git checkout docs/gaps.yaml  # restore so we don't leave the working tree dirty
    exit 1
fi

if [[ "$CHANGED_GAPS" -gt "$MAX_GAPS" ]]; then
    warn "Diff has ${CHANGED_GAPS} status:done flips — exceeds --max-gaps ${MAX_GAPS}"
    warn "This is unusually large. Refusing automatic ship; operator should review."
    git checkout docs/gaps.yaml
    exit 1
fi

say "Found ${CHANGED_GAPS} gap closure(s) to batch."

if [[ "$DRY_RUN" -eq 1 ]]; then
    say "DRY-RUN — diff:"
    git diff --stat docs/gaps.yaml
    git checkout docs/gaps.yaml
    exit 0
fi

# ── Ship ─────────────────────────────────────────────────────────────────────
DATE=$(date -u +%Y-%m-%d)
COMMIT_MSG="chore(close): batch yaml regen for ${CHANGED_GAPS} gap closure(s) ${DATE}

Drove from .chump/state.db (canonical) → docs/gaps.yaml. Catches gap
closures that bypassed INFRA-154's per-PR auto-flip path:
  - Drive-by 'chump gap set <ID> --status done' calls
  - Cold Water sweep flips
  - Manual ships not via bot-merge.sh
  - INFRA-154 hook failed silently

Closures included (from state.db):
$(chump gap list --status done --json 2>/dev/null \
    | python3 -c "
import json, sys, datetime
today = datetime.date.today().isoformat()
data = json.load(sys.stdin)
recent = [g for g in data if (g.get('closed_date') or '') >= '${DATE}']
recent.sort(key=lambda g: g.get('id',''))
for g in recent[:25]:
    print(f\"  - {g['id']:18} closed_pr={g.get('closed_pr','—')} {g.get('title','')[:60]}\")
" 2>/dev/null || echo "  (per-gap detail unavailable)")

INFRA-194 batcher run: \$(date -u +%Y-%m-%dT%H:%M:%SZ)"

CHUMP_AMBIENT_GLANCE=0 CHUMP_GAP_CHECK=0 CHUMP_GAPS_LOCK=0 git add docs/gaps.yaml \
    && git commit -m "$COMMIT_MSG" --no-verify >/dev/null 2>&1 \
    || die "commit failed" 2

if [[ "$SKIP_BOT_MERGE" -eq 1 ]]; then
    say "Committed locally. Skipping bot-merge.sh per --skip-bot-merge."
    say "  Push manually: CHUMP_GAP_CHECK=0 git push origin '$BRANCH'"
    exit 0
fi

# Use bot-merge.sh for the standard ship pipeline (handles pr-watch.sh
# auto-recovery via the INFRA-190 hook).
say "Shipping via bot-merge.sh…"
if scripts/coord/bot-merge.sh --auto-merge --skip-tests; then
    say "✓ batched closer PR shipped"
    exit 0
else
    die "bot-merge.sh failed" 2
fi
