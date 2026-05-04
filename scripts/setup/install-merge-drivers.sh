#!/usr/bin/env bash
# install-merge-drivers.sh — INFRA-310 / INFRA-367
#
# Register chump's custom git merge drivers in the local git config.
# Idempotent — safe to re-run.
#
# Wiring is split between:
#   - .gitattributes (committed) — declares which paths use which driver
#   - .git/config (NOT committed) — registers the driver command
#
# Without the .git/config registration, .gitattributes references drivers
# that git can't find, and merges fall back to default 3-way (which produces
# conflict markers — same as no driver at all). So this installer is required
# once per checkout / per linked worktree.
#
# Auto-installed by scripts/setup/install-hooks.sh (which agents run via
# `bot-merge.sh` and `post-checkout` hook), so most operators never need to
# run it directly. Manual invocation:
#
#   bash scripts/setup/install-merge-drivers.sh
#
# Verify all drivers:
#   git config --get-regexp '^merge\.' | grep -E 'driver|name'
#
# Drivers registered (INFRA-310):
#   chump-state-sql-regen: regenerates .chump/state.sql from .chump/state.db on conflict
#   ci-yml-add-row: merges .github/workflows/ci.yml step additions
#   pre-commit-add-guard: merges scripts/git-hooks/pre-commit guard additions

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
    echo "[install-merge-drivers] not in a git repo — nothing to do" >&2
    exit 1
fi
cd "$REPO_ROOT"

# ── Register state.sql regeneration driver ────────────────────────────────────
DRIVER_SCRIPT_REL="scripts/git/merge-driver-state-sql-regen.sh"
DRIVER_NAME="chump-state-sql-regen"

if [[ -x "$DRIVER_SCRIPT_REL" ]]; then
    git config "merge.${DRIVER_NAME}.name" "Regenerate .chump/state.sql from .chump/state.db on conflict (INFRA-310)"
    git config "merge.${DRIVER_NAME}.driver" "${DRIVER_SCRIPT_REL} %O %A %B %L"
    echo "[install-merge-drivers] OK: ${DRIVER_NAME} registered"
else
    echo "[install-merge-drivers] SKIP: ${DRIVER_SCRIPT_REL} not found" >&2
fi

# ── Register CI YAML add-row driver ──────────────────────────────────────────
DRIVER_SCRIPT_REL="scripts/git/merge-driver-ci-yml-add-row.sh"
DRIVER_NAME="ci-yml-add-row"

if [[ -x "$DRIVER_SCRIPT_REL" ]]; then
    git config "merge.${DRIVER_NAME}.name" "Union .github/workflows/ci.yml step additions (INFRA-310)"
    git config "merge.${DRIVER_NAME}.driver" "${DRIVER_SCRIPT_REL} %O %A %B %L"
    echo "[install-merge-drivers] OK: ${DRIVER_NAME} registered"
else
    echo "[install-merge-drivers] SKIP: ${DRIVER_SCRIPT_REL} not found" >&2
fi

# ── Register pre-commit add-guard driver ─────────────────────────────────────
DRIVER_SCRIPT_REL="scripts/git/merge-driver-pre-commit-add-guard.sh"
DRIVER_NAME="pre-commit-add-guard"

if [[ -x "$DRIVER_SCRIPT_REL" ]]; then
    git config "merge.${DRIVER_NAME}.name" "Append scripts/git-hooks/pre-commit guard blocks (INFRA-310)"
    git config "merge.${DRIVER_NAME}.driver" "${DRIVER_SCRIPT_REL} %O %A %B %L"
    echo "[install-merge-drivers] OK: ${DRIVER_NAME} registered"
else
    echo "[install-merge-drivers] SKIP: ${DRIVER_SCRIPT_REL} not found" >&2
fi

# Verify .gitattributes wiring
if [[ -f .gitattributes ]]; then
    echo "[install-merge-drivers] .gitattributes wiring check:"
    for pattern in ".chump/state.sql" ".github/workflows/ci.yml" "scripts/git-hooks/pre-commit"; do
        if grep -qF "$pattern" .gitattributes 2>/dev/null; then
            echo "[install-merge-drivers]   ✓ $pattern configured"
        else
            echo "[install-merge-drivers]   ⚠ $pattern not found in .gitattributes" >&2
        fi
    done
fi
