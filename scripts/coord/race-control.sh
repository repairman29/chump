#!/usr/bin/env bash
# race-control.sh — CREDIBLE-296: live merge-mix board + waste-over-threshold alarm
#
# "Nobody watches the tape" — this is the tape. Reads the last N merged PRs to
# main and classifies each into one of three buckets by title/label heuristic:
#
#   user-value        — PRs that ship product-facing / customer-visible value
#   self-maintenance  — PRs that maintain fleet plumbing (curators, CI, docs,
#                        scripts, tooling, governance) — necessary, but not
#                        user-facing value
#   reconcile-waste    — PRs that only reconcile already-stale bookkeeping
#                        (stale gap YAML, "already shipped via #N", closing a
#                        roster/manifest coherence gap, re-dispositioning an
#                        already-decided gate) — pure overhead that a healthier
#                        pipeline would not have needed to produce
#
# Classification is title/label based (conventional-commit prefix + keyword
# match, checked reconcile-waste first as the most specific bucket) so it
# works offline against a JSON fixture (gh API PR list shape) with no network
# calls in tests. See CLASSIFY_* regexes below — kept inline so the rules are
# reviewable in the same file that applies them (AC5).
#
# Output:
#   - stdout: human-readable summary (or JSON with --json)
#   - ~/.chump/metrics/race-control.jsonl: daily rows (append-only)
#   - ambient.jsonl: kind=race_control_mix on every run (AC2 — the signal is
#     not stdout-only)
#   - ambient.jsonl + duty-officer channel: kind=race_control_waste_alarm +
#     non-zero exit when reconcile-waste% exceeds --threshold (AC3)
#
# Usage:
#   bash scripts/coord/race-control.sh                # last 60 merged PRs
#   bash scripts/coord/race-control.sh --window 100
#   bash scripts/coord/race-control.sh --json
#   bash scripts/coord/race-control.sh --dry-run       # no writes, no alarm broadcast
#   bash scripts/coord/race-control.sh --threshold 25  # alarm at 25%
#
# Env:
#   CHUMP_RACE_WINDOW           — default window size (overridden by --window)
#   CHUMP_RACE_WASTE_THRESHOLD  — default alarm threshold pct (overridden by --threshold)
#   CHUMP_RACE_FIXTURE          — offline fixture path: JSON array of
#                                  {number, title, labels: [str,...]} objects,
#                                  no gh network calls when set
#   CHUMP_RACE_DATE             — inject a deterministic date into the JSONL row
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then MAIN_REPO="$REPO_ROOT"; else MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"; fi

AMBIENT="${CHUMP_AMBIENT_LOG:-$MAIN_REPO/.chump-locks/ambient.jsonl}"
METRICS_DIR="${CHUMP_METRICS_DIR:-$HOME/.chump/metrics}"
METRICS_FILE="$METRICS_DIR/race-control.jsonl"

# ── Classification rules (AC5: documented inline) ────────────────────────────
# Checked in order: reconcile-waste (most specific — pure bookkeeping
# overhead) -> user-value (product/customer-facing) -> self-maintenance
# (default bucket: everything that keeps the fleet itself running).
RECONCILE_WASTE_RE='reconcile|already shipped|already dispositioned|stale .*(yaml|comment)|pending decision|roll.call|roster/manifest coherence|coherence gap|re.file|duplicate|\bdup\b|orphan.*gap|ghost.gap|gap.status.*drift'
USER_VALUE_RE='^(feat|fix)\((product|marcus|web|api)\)|customer.facing|user.facing|\bpitch\b|\bdemo\b|\bonboarding\b'
# self-maintenance is the default bucket (docs, chore, gaps, governance,
# curators, daemons, CI, process) — everything not caught above.

LIMIT="${CHUMP_RACE_WINDOW:-60}"
THRESHOLD="${CHUMP_RACE_WASTE_THRESHOLD:-30}"
AS_JSON=0
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --window|-w)  LIMIT="$2"; shift 2 ;;
        --limit)      LIMIT="$2"; shift 2 ;;
        --json)       AS_JSON=1; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --threshold)  THRESHOLD="$2"; shift 2 ;;
        *)            echo "[race-control] unknown arg: $1" >&2; exit 2 ;;
    esac
done

TODAY="${CHUMP_RACE_DATE:-$(date -u +%Y-%m-%d)}"

# ── Fetch merged PRs ──────────────────────────────────────────────────────────
if [[ -n "${CHUMP_RACE_FIXTURE:-}" ]]; then
    MERGED_PRS="$(cat "$CHUMP_RACE_FIXTURE")"
else
    REPO_SLUG="$(git -C "$MAIN_REPO" remote get-url origin 2>/dev/null \
        | sed -E 's|.*github.com[:/]||; s|\.git$||')" || REPO_SLUG=""

    if [[ -z "$REPO_SLUG" ]] || ! command -v gh &>/dev/null; then
        echo "[race-control] ERROR: need gh CLI and a GitHub remote" >&2
        exit 1
    fi

    MERGED_PRS="$(CHUMP_GH_CALL_CRITICALITY=background gh api \
        "repos/$REPO_SLUG/pulls?state=closed&sort=updated&direction=desc&per_page=$LIMIT" \
        --jq '[.[] | select(.merged_at != null) | {number: .number, title: .title, labels: [.labels[].name]}]' \
        2>/dev/null || echo '[]')"
fi

TOTAL="$(echo "$MERGED_PRS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)"

if [[ "$TOTAL" -eq 0 ]]; then
    echo "[race-control] No merged PRs found (offline or empty repo)" >&2
    exit 0
fi

# ── Classify each PR (python does the regex work; bash just tallies) ─────────
CLASS_JSON="$(echo "$MERGED_PRS" | RECONCILE_RE="$RECONCILE_WASTE_RE" USER_VALUE_RE="$USER_VALUE_RE" python3 -c "
import json, os, re, sys

prs = json.load(sys.stdin)
reconcile_re = re.compile(os.environ['RECONCILE_RE'], re.IGNORECASE)
user_value_re = re.compile(os.environ['USER_VALUE_RE'], re.IGNORECASE)

counts = {'user-value': 0, 'self-maintenance': 0, 'reconcile-waste': 0}
for pr in prs:
    title = pr.get('title') or ''
    labels = ' '.join(pr.get('labels') or [])
    hay = title + ' ' + labels
    if 'reconcile-waste' in labels.lower():
        counts['reconcile-waste'] += 1
    elif 'user-value' in labels.lower():
        counts['user-value'] += 1
    elif 'self-maintenance' in labels.lower():
        counts['self-maintenance'] += 1
    elif reconcile_re.search(hay):
        counts['reconcile-waste'] += 1
    elif user_value_re.search(hay):
        counts['user-value'] += 1
    else:
        counts['self-maintenance'] += 1

print(json.dumps(counts))
")"

USER_VALUE_COUNT="$(echo "$CLASS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['user-value'])")"
SELF_MAINT_COUNT="$(echo "$CLASS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['self-maintenance'])")"
RECONCILE_WASTE_COUNT="$(echo "$CLASS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['reconcile-waste'])")"

USER_VALUE_PCT="$(python3 -c "print(round(100*$USER_VALUE_COUNT/$TOTAL, 1))")"
SELF_MAINT_PCT="$(python3 -c "print(round(100*$SELF_MAINT_COUNT/$TOTAL, 1))")"
RECONCILE_WASTE_PCT="$(python3 -c "print(round(100*$RECONCILE_WASTE_COUNT/$TOTAL, 1))")"

ROW="{\"date\":\"$TODAY\",\"window\":$TOTAL,\"user_value_count\":$USER_VALUE_COUNT,\"self_maintenance_count\":$SELF_MAINT_COUNT,\"reconcile_waste_count\":$RECONCILE_WASTE_COUNT,\"user_value_pct\":$USER_VALUE_PCT,\"self_maintenance_pct\":$SELF_MAINT_PCT,\"reconcile_waste_pct\":$RECONCILE_WASTE_PCT}"

if [[ "$AS_JSON" -eq 1 ]]; then
    echo "$ROW"
else
    echo "=== Race Control: Merge-Mix Board (CREDIBLE-296) ==="
    echo "  Window:             last $TOTAL merged PRs"
    echo "  user-value:         ${USER_VALUE_PCT}% ($USER_VALUE_COUNT)"
    echo "  self-maintenance:   ${SELF_MAINT_PCT}% ($SELF_MAINT_COUNT)"
    echo "  reconcile-waste:    ${RECONCILE_WASTE_PCT}% ($RECONCILE_WASTE_COUNT)"
    echo "  Alarm threshold:    reconcile-waste > ${THRESHOLD}%"
    echo ""
fi

# ── Write metrics row ──────────────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p "$METRICS_DIR"
    echo "$ROW" >> "$METRICS_FILE"
fi

# ── AC2: machine-readable ambient event, every run ────────────────────────────
# scanner-anchor: "kind":"race_control_mix"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MIX_EVENT="{\"ts\":\"$TS\",\"kind\":\"race_control_mix\",\"window\":$TOTAL,\"user_value_pct\":$USER_VALUE_PCT,\"self_maintenance_pct\":$SELF_MAINT_PCT,\"reconcile_waste_pct\":$RECONCILE_WASTE_PCT}"
if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    echo "$MIX_EVENT" >> "$AMBIENT" 2>/dev/null || true
fi

# ── AC3: waste-over-threshold alarm, routed through the ambient/duty-officer
# channel (not just a log line) ────────────────────────────────────────────────
EXIT_CODE=0
ALARM="$(python3 -c "print('1' if float('$RECONCILE_WASTE_PCT') > float('$THRESHOLD') else '0')" 2>/dev/null || echo "0")"
if [[ "$ALARM" == "1" ]]; then
    EXIT_CODE=1
    # scanner-anchor: "kind":"race_control_waste_alarm"
    ALARM_EVENT="{\"ts\":\"$TS\",\"kind\":\"race_control_waste_alarm\",\"reconcile_waste_pct\":$RECONCILE_WASTE_PCT,\"threshold_pct\":$THRESHOLD,\"window\":$TOTAL}"
    MSG="race-control: reconcile-waste ${RECONCILE_WASTE_PCT}% exceeds threshold ${THRESHOLD}% (window=$TOTAL)"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        # Writes to the same ambient.jsonl stream duty-officer-loop.sh `tick`
        # scans (docs/design/DUTY_OFFICER.md §4) and PLAYBOOK_REGISTRY.yaml's
        # race_control_waste_alarm signal routes on — the shared board/
        # duty-officer channel, not a private log file.
        echo "$ALARM_EVENT" >> "$AMBIENT" 2>/dev/null || true
    fi
    echo "[race-control] ALARM: $MSG" >&2
fi

exit "$EXIT_CODE"
