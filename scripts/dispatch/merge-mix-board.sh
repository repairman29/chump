#!/usr/bin/env bash
# merge-mix-board.sh — CREDIBLE-296: Race Control live merge-mix board
#
# "Nobody watches the tape" — this is the tape. Classifies the last N merged
# PRs into three buckets and reports the mix as percentages:
#
#   user-value%      — PRs that ship product-facing / customer-visible value
#   self-maint%       — PRs that maintain fleet plumbing (curators, CI, docs,
#                        scripts, tooling) — necessary, but not user value
#   reconcile-waste%  — PRs that only reconcile already-stale bookkeeping
#                        (stale gap YAML, "already shipped via #N", dispositions
#                        of already-closed decisions) — pure overhead that a
#                        healthier pipeline would not have needed to produce
#
# Classification is title-based (conventional-commit prefix + keyword match)
# so it works offline against a JSON fixture (gh API PR list shape) with no
# network calls in tests.
#
# Output:
#   - stdout: human-readable summary (or JSON with --json)
#   - ~/.chump/metrics/merge-mix-board.jsonl: daily rows (append-only)
#   - ambient.jsonl: kind=merge_mix_waste_threshold_breach when
#     reconcile-waste% exceeds the alarm threshold (default 40%)
#
# Usage:
#   bash scripts/dispatch/merge-mix-board.sh                # last 60 merged PRs
#   bash scripts/dispatch/merge-mix-board.sh --window 100
#   bash scripts/dispatch/merge-mix-board.sh --json
#   bash scripts/dispatch/merge-mix-board.sh --dry-run       # no writes
#   bash scripts/dispatch/merge-mix-board.sh --threshold 30  # alarm at 30%
#
# Fixture mode (offline / testing):
#   CHUMP_MMB_FIXTURE=/path/to/prs.json — reads PR list from file instead of gh.
#   The fixture must be a JSON array of {number, title} objects.
#
# Injectable date (for deterministic tests):
#   CHUMP_MMB_DATE=2026-01-15 — override today's date in the JSONL row.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then MAIN_REPO="$REPO_ROOT"; else MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"; fi

AMBIENT="${CHUMP_AMBIENT_LOG:-$MAIN_REPO/.chump-locks/ambient.jsonl}"
METRICS_DIR="${CHUMP_METRICS_DIR:-$HOME/.chump/metrics}"
METRICS_FILE="$METRICS_DIR/merge-mix-board.jsonl"

# Classification patterns (case-insensitive). Order matters: reconcile-waste
# is checked first (most specific — pure bookkeeping overhead), then
# user-value (product/customer-facing), with self-maint as the default
# bucket for everything else (fleet plumbing).
RECONCILE_WASTE_RE='reconcile stale|already shipped via|disposition|stale .*(yaml|comment)|pending decision|ghost.gap|gap-status'
USER_VALUE_RE='^(feat|fix)\((product|marcus|web)|customer.facing|user.facing|\bpitch\b|\bdemo\b'

LIMIT=60
AS_JSON=0
DRY_RUN=0
THRESHOLD=40
while [[ $# -gt 0 ]]; do
    case "$1" in
        --window|-w)  LIMIT="$2"; shift 2 ;;
        --limit)      LIMIT="$2"; shift 2 ;;
        --json)       AS_JSON=1; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --threshold)  THRESHOLD="$2"; shift 2 ;;
        *)            echo "[merge-mix-board] unknown arg: $1" >&2; exit 2 ;;
    esac
done

TODAY="${CHUMP_MMB_DATE:-$(date -u +%Y-%m-%d)}"

# ── Fetch merged PRs ───────────────────────────────────────────────────────────
if [[ -n "${CHUMP_MMB_FIXTURE:-}" ]]; then
    MERGED_PRS="$(cat "$CHUMP_MMB_FIXTURE")"
else
    REPO_SLUG="$(git -C "$MAIN_REPO" remote get-url origin 2>/dev/null \
        | sed -E 's|.*github.com[:/]||; s|\.git$||')" || REPO_SLUG=""

    if [[ -z "$REPO_SLUG" ]] || ! command -v gh &>/dev/null; then
        echo "[merge-mix-board] ERROR: need gh CLI and a GitHub remote" >&2
        exit 1
    fi

    MERGED_PRS="$(CHUMP_GH_CALL_CRITICALITY=background gh api \
        "repos/$REPO_SLUG/pulls?state=closed&sort=updated&direction=desc&per_page=$LIMIT" \
        --jq '[.[] | select(.merged_at != null) | {number: .number, title: .title}]' \
        2>/dev/null || echo '[]')"
fi

TOTAL="$(echo "$MERGED_PRS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)"

if [[ "$TOTAL" -eq 0 ]]; then
    echo "[merge-mix-board] No merged PRs found (offline or empty repo)" >&2
    exit 0
fi

# ── Classify each PR (python does the regex work; bash just tallies) ─────────
CLASS_JSON="$(echo "$MERGED_PRS" | RECONCILE_RE="$RECONCILE_WASTE_RE" USER_VALUE_RE="$USER_VALUE_RE" python3 -c "
import json, os, re, sys

prs = json.load(sys.stdin)
reconcile_re = re.compile(os.environ['RECONCILE_RE'], re.IGNORECASE)
user_value_re = re.compile(os.environ['USER_VALUE_RE'], re.IGNORECASE)

counts = {'user-value': 0, 'self-maint': 0, 'reconcile-waste': 0}
for pr in prs:
    title = pr.get('title') or ''
    if reconcile_re.search(title):
        counts['reconcile-waste'] += 1
    elif user_value_re.search(title):
        counts['user-value'] += 1
    else:
        counts['self-maint'] += 1

print(json.dumps(counts))
")"

USER_VALUE_COUNT="$(echo "$CLASS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['user-value'])")"
SELF_MAINT_COUNT="$(echo "$CLASS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['self-maint'])")"
RECONCILE_WASTE_COUNT="$(echo "$CLASS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['reconcile-waste'])")"

USER_VALUE_PCT="$(python3 -c "print(round(100*$USER_VALUE_COUNT/$TOTAL, 1))")"
SELF_MAINT_PCT="$(python3 -c "print(round(100*$SELF_MAINT_COUNT/$TOTAL, 1))")"
RECONCILE_WASTE_PCT="$(python3 -c "print(round(100*$RECONCILE_WASTE_COUNT/$TOTAL, 1))")"

ROW="{\"date\":\"$TODAY\",\"total_prs\":$TOTAL,\"user_value_count\":$USER_VALUE_COUNT,\"self_maint_count\":$SELF_MAINT_COUNT,\"reconcile_waste_count\":$RECONCILE_WASTE_COUNT,\"user_value_pct\":$USER_VALUE_PCT,\"self_maint_pct\":$SELF_MAINT_PCT,\"reconcile_waste_pct\":$RECONCILE_WASTE_PCT}"

if [[ "$AS_JSON" -eq 1 ]]; then
    echo "$ROW"
else
    echo "=== Race Control: Merge-Mix Board (CREDIBLE-296) ==="
    echo "  Window:            last $TOTAL merged PRs"
    echo "  user-value:        ${USER_VALUE_PCT}% ($USER_VALUE_COUNT)"
    echo "  self-maint:        ${SELF_MAINT_PCT}% ($SELF_MAINT_COUNT)"
    echo "  reconcile-waste:   ${RECONCILE_WASTE_PCT}% ($RECONCILE_WASTE_COUNT)"
    echo "  Alarm threshold:   reconcile-waste > ${THRESHOLD}%"
    echo ""
fi

# ── Write to metrics file ──────────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p "$METRICS_DIR"
    echo "$ROW" >> "$METRICS_FILE"
fi

# ── Waste-over-threshold alarm ────────────────────────────────────────────────
# scanner-anchor: "kind":"merge_mix_waste_threshold_breach" (INFRA-754 pairing;
# the actual emit below builds this JSON with escaped quotes so the registry
# scanner's literal-quote needle can't match it directly)
ALARM="$(python3 -c "print('1' if float('$RECONCILE_WASTE_PCT') > float('$THRESHOLD') else '0')" 2>/dev/null || echo "0")"
if [[ "$ALARM" == "1" ]]; then
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    EVENT="{\"ts\":\"$TS\",\"kind\":\"merge_mix_waste_threshold_breach\",\"reconcile_waste_pct\":$RECONCILE_WASTE_PCT,\"threshold_pct\":$THRESHOLD,\"total_prs\":$TOTAL}"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        echo "$EVENT" >> "$AMBIENT" 2>/dev/null || true
    fi
    [[ "$AS_JSON" -eq 0 ]] && echo "$EVENT"
    echo "[merge-mix-board] ALARM: reconcile-waste ${RECONCILE_WASTE_PCT}% exceeds threshold ${THRESHOLD}%" >&2
fi
