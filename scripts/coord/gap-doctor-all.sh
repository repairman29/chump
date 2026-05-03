#!/usr/bin/env bash
# scripts/coord/gap-doctor-all.sh — INFRA-320
#
# Unified entry point for the gap-doctor reconciler toolchain. Runs (in
# order) all 4 scripts that came out of the 2026-05-02 fleet session:
#
#   1. gap-doctor.py doctor                         — diagnose drift (read-only)
#   2. gap-normalize-domains.sh                     — collapse domain field variants (UPPER + semantic)
#   3. gap-doctor-reconcile.py                      — backfill state.db missing fields from YAML
#   4. gap-doctor-backfill-closed-pr.sh             — backfill closed_pr from gh merged PRs
#   5. gap-doctor.py doctor                         — verify drift now zero
#
# Each step is independently runnable; this orchestrator just chains them
# with consistent reporting. Idempotent — safe to re-run nightly. State.db
# is gitignored so this MUST run locally on each operator's machine.
#
# Usage:
#   bash scripts/coord/gap-doctor-all.sh             # apply
#   bash scripts/coord/gap-doctor-all.sh --dry-run   # report only (passes through)
#
# Recommended cron: nightly via launchd (pairs with overnight scheduler).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts/coord"

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

step() { printf '\n\033[1;36m[gap-doctor-all] %s\033[0m\n' "$*"; }

step "Step 1/5 — diagnose drift (before)"
python3 "$SCRIPT_DIR/gap-doctor.py" doctor 2>&1 | head -8

step "Step 2/5 — normalize domain field"
if [[ -x "$SCRIPT_DIR/gap-normalize-domains.sh" ]]; then
    if [[ $DRY -eq 1 ]]; then
        bash "$SCRIPT_DIR/gap-normalize-domains.sh" --dry-run | head -3
    else
        bash "$SCRIPT_DIR/gap-normalize-domains.sh" 2>&1 | tail -2
    fi
else
    echo "  SKIP: gap-normalize-domains.sh not found (INFRA-318 not yet landed?)"
fi

step "Step 3/5 — reconcile YAML → state.db (fields)"
if [[ -x "$SCRIPT_DIR/gap-doctor-reconcile.py" ]]; then
    if [[ $DRY -eq 1 ]]; then
        python3 "$SCRIPT_DIR/gap-doctor-reconcile.py" --dry-run 2>&1 | tail -5
    else
        python3 "$SCRIPT_DIR/gap-doctor-reconcile.py" 2>&1 | tail -5
    fi
else
    echo "  SKIP: gap-doctor-reconcile.py not found (INFRA-303 not yet landed?)"
fi

step "Step 4/5 — backfill closed_pr from gh"
if [[ -x "$SCRIPT_DIR/gap-doctor-backfill-closed-pr.sh" ]]; then
    if [[ $DRY -eq 1 ]]; then
        bash "$SCRIPT_DIR/gap-doctor-backfill-closed-pr.sh" --dry-run --limit 10 2>&1 | tail -8
    else
        bash "$SCRIPT_DIR/gap-doctor-backfill-closed-pr.sh" 2>&1 | tail -6
    fi
else
    echo "  SKIP: gap-doctor-backfill-closed-pr.sh not found (INFRA-319 not yet landed?)"
fi

step "Step 5/5 — verify drift (after)"
python3 "$SCRIPT_DIR/gap-doctor.py" doctor 2>&1 | head -8

step "done"
[[ $DRY -eq 1 ]] && step "DRY-RUN — no writes applied"
