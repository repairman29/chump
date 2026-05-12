#!/usr/bin/env bash
# gap-curate.sh — INFRA-637
# Nightly gap-store self-curate: rebalance + consolidate + retention-sweep.
# Emits kind=gap_store_curated to ambient.jsonl with counts.
#
# Usage:
#   scripts/ops/gap-curate.sh [--dry-run] [--quiet]
#
# Environment:
#   CHUMP_GAP_CURATE_DISABLE=1   Skip all curation (opt-out for CI/offline).
#
# Exit codes:
#   0  Curation ran (or disabled).
#   2  Usage error.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHUMP="$REPO_ROOT/target/debug/chump"
[[ -x "$CHUMP" ]] || CHUMP="$(command -v chump 2>/dev/null)" || CHUMP=""

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
SESSION="${SESSION_ID:-$(hostname)-$$}"
DRY_RUN=0
QUIET=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --quiet)   QUIET=1;   shift ;;
        --help|-h)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "gap-curate.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

if [[ "${CHUMP_GAP_CURATE_DISABLE:-0}" == "1" ]]; then
    [[ "$QUIET" -eq 0 ]] && echo "[gap-curate] CHUMP_GAP_CURATE_DISABLE=1 — skipping"
    exit 0
fi

if [[ -z "$CHUMP" ]]; then
    echo "[gap-curate] WARN: chump binary not found — skip curation" >&2
    exit 0
fi

rebalanced=0
consolidated=0
retained=0
errors=0

run_step() {
    local label="$1"; shift
    local cmd=("$@")
    [[ "$QUIET" -eq 0 ]] && echo "[gap-curate] running: ${cmd[*]}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[gap-curate] [dry-run] would run: ${cmd[*]}" >&2
        return 0
    fi
    if "${cmd[@]}" >/dev/null 2>&1; then
        [[ "$QUIET" -eq 0 ]] && echo "[gap-curate] OK: $label"
        return 0
    else
        [[ "$QUIET" -eq 0 ]] && echo "[gap-curate] WARN: $label exited non-zero (skipping)" >&2
        errors=$(( errors + 1 ))
        return 0
    fi
}

# ── Step 1: rebalance (P0 budget + pillar floor enforcement) ─────────────────
if run_step "rebalance" "$CHUMP" gap rebalance --apply; then
    rebalanced=1
fi

# ── Step 2: consolidate (deduplicate near-identical gaps) ────────────────────
# This sub-command may not be implemented yet (INFRA-619); skip gracefully.
if "$CHUMP" gap consolidate --help >/dev/null 2>&1; then
    if run_step "consolidate" "$CHUMP" gap consolidate --apply; then
        consolidated=1
    fi
else
    [[ "$QUIET" -eq 0 ]] && echo "[gap-curate] INFO: 'chump gap consolidate' not available — skipping (INFRA-619)"
fi

# ── Step 3: retention-sweep (idle >90d → P3 with auto-justification) ─────────
# This sub-command may not be implemented yet; skip gracefully.
if "$CHUMP" gap retention-sweep --help >/dev/null 2>&1; then
    if run_step "retention-sweep" "$CHUMP" gap retention-sweep --apply; then
        retained=1
    fi
else
    [[ "$QUIET" -eq 0 ]] && echo "[gap-curate] INFO: 'chump gap retention-sweep' not available — skipping"
fi

# ── Emit ambient event ───────────────────────────────────────────────────────
payload=$(printf \
    '{"ts":"%s","kind":"gap_store_curated","session":"%s","rebalanced":%d,"consolidated":%d,"retained":%d,"errors":%d}' \
    "$(ts)" "$SESSION" "$rebalanced" "$consolidated" "$retained" "$errors")

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[gap-curate] [dry-run] would emit: $payload" >&2
else
    echo "$payload" >> "$AMBIENT" 2>/dev/null || true
fi

[[ "$QUIET" -eq 0 ]] && echo "[gap-curate] done (rebalanced=$rebalanced consolidated=$consolidated retained=$retained errors=$errors)"
exit 0
