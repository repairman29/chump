#!/usr/bin/env bash
# scripts/ops/github-cache-divergence-audit.sh — INFRA-3833
#
# Nightly divergence check between the Python webhook receiver
# (scripts/ops/github-webhook-receiver.py) and the Rust webhook receiver
# (chump-webhook-receiver / crates/chump-github-cache/src/webhook.rs).
# Both write into the same `pr_state` row during the 14-day parallel-run
# validation window (INFRA-2062 AC1) — each also appends its own view to
# the append-only `pr_state_write_log` table (source='python'|'rust').
# This script diffs the latest python row vs the latest rust row per PR
# number and emits `kind=cache_divergence_detected` on any mismatch, so
# the 14-day zero-divergence window INFRA-2062 needs can actually be
# measured instead of claimed on faith.
#
# Usage:
#   scripts/ops/github-cache-divergence-audit.sh [--window-hours N]
#
# Exit code: always 0 (an audit script that fails the host process on
# finding is itself a reliability risk). Divergence findings are
# reported via the ambient event, not the exit code.
#
# Designed to run nightly (no launchd plist installed by this gap — see
# INFRA-3833 AC4; wiring a cron entry is a follow-up once the 14-day
# window actually starts).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"

CACHE_DB="${CHUMP_CACHE_DB:-$REPO/.chump/github_cache.db}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO/.chump-locks/ambient.jsonl}"
WINDOW_HOURS="${CHUMP_DIVERGENCE_WINDOW_HOURS:-24}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --window-hours) WINDOW_HOURS="$2"; shift 2 ;;
        *) echo "[divergence-audit] unknown arg: $1" >&2; exit 0 ;;
    esac
done

if [[ ! -f "$CACHE_DB" ]]; then
    echo "[divergence-audit] no cache DB at $CACHE_DB — nothing to audit"
    exit 0
fi

has_log_table="$(sqlite3 "$CACHE_DB" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='pr_state_write_log';" 2>/dev/null || echo 0)"
if [[ "$has_log_table" != "1" ]]; then
    echo "[divergence-audit] pr_state_write_log table does not exist yet — nothing to audit"
    exit 0
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cutoff="$(date -u -d "-${WINDOW_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"${WINDOW_HOURS}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"

# For each PR number with log rows from BOTH sources within the window,
# compare the latest-per-source row. `GROUP BY number` picks the MAX(id)
# per (number, source) via a correlated subquery — small table, nightly
# cadence, no performance concern.
mismatches="$(sqlite3 -separator $'\t' "$CACHE_DB" "
WITH latest AS (
    SELECT l.number, l.source, l.mergeable_state, l.auto_merge_enabled, l.draft, l.title
    FROM pr_state_write_log l
    JOIN (
        SELECT number, source, MAX(id) AS max_id
        FROM pr_state_write_log
        WHERE written_at >= '$cutoff'
        GROUP BY number, source
    ) m ON l.id = m.max_id
)
SELECT p.number,
       COALESCE(p.mergeable_state,''), COALESCE(r.mergeable_state,''),
       p.auto_merge_enabled, r.auto_merge_enabled,
       p.draft, r.draft,
       COALESCE(p.title,''), COALESCE(r.title,'')
FROM latest p
JOIN latest r ON p.number = r.number AND p.source = 'python' AND r.source = 'rust'
WHERE p.mergeable_state IS NOT r.mergeable_state
   OR p.auto_merge_enabled != r.auto_merge_enabled
   OR p.draft != r.draft
   OR p.title IS NOT r.title
" 2>/dev/null || true)"

if [[ -z "$mismatches" ]]; then
    echo "[divergence-audit] no divergence found (window=${WINDOW_HOURS}h, cutoff=$cutoff)"
    exit 0
fi

count=0
while IFS=$'\t' read -r number py_state rs_state py_am rs_am py_draft rs_draft py_title rs_title; do
    [[ -z "$number" ]] && continue
    count=$((count + 1))
    # Python-side json.dumps / bash printf both handle quote-escaping for
    # us here via printf %s inside a JSON string — titles are the only
    # free-text field and GitHub PR titles rarely contain raw double
    # quotes, but escape defensively anyway.
    esc_py_title="${py_title//\"/\\\"}"
    esc_rs_title="${rs_title//\"/\\\"}"
    printf '{"ts":"%s","kind":"cache_divergence_detected","pr_number":%s,"python":{"mergeable_state":"%s","auto_merge_enabled":%s,"draft":%s,"title":"%s"},"rust":{"mergeable_state":"%s","auto_merge_enabled":%s,"draft":%s,"title":"%s"}}\n' \
        "$ts" "$number" "$py_state" "$py_am" "$py_draft" "$esc_py_title" \
        "$rs_state" "$rs_am" "$rs_draft" "$esc_rs_title" \
        >> "$AMBIENT" 2>/dev/null || true
done <<< "$mismatches"

echo "[divergence-audit] found $count divergent PR(s) in the last ${WINDOW_HOURS}h — emitted kind=cache_divergence_detected"
exit 0
