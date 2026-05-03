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
# Without the .git/config registration, .gitattributes references a driver
# that git can't find, and the merge falls back to default 3-way (which
# produces conflict markers — same as no driver at all). So this installer
# is required once per checkout / per linked worktree.
#
# Auto-installed by scripts/setup/install-hooks.sh (which agents run via
# `bot-merge.sh` and `post-checkout` hook), so most operators never need to
# run it directly. Manual invocation:
#
#   bash scripts/setup/install-merge-drivers.sh
#
# Verify:
#   git config --get merge.chump-state-sql-regen.driver

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
    echo "[install-merge-drivers] not in a git repo — nothing to do" >&2
    exit 1
fi
cd "$REPO_ROOT"

DRIVER_SCRIPT_REL="scripts/git/merge-driver-state-sql-regen.sh"
DRIVER_NAME="chump-state-sql-regen"

if [[ ! -x "$DRIVER_SCRIPT_REL" ]]; then
    echo "[install-merge-drivers] driver script $DRIVER_SCRIPT_REL not found or not executable" >&2
    exit 1
fi

# Register driver name + command. `git config` is idempotent: re-setting the
# same value is a no-op.
git config "merge.${DRIVER_NAME}.name" "Regenerate .chump/state.sql from .chump/state.db on conflict (INFRA-310)"
git config "merge.${DRIVER_NAME}.driver" "${DRIVER_SCRIPT_REL} %O %A %B %P"

# Verify .gitattributes contains the wiring. If not, warn — we don't write
# the .gitattributes line ourselves (that's a committed file the PR
# introduces). This is the "is the PR landed?" check.
if [[ -f .gitattributes ]] && grep -qF ".chump/state.sql merge=${DRIVER_NAME}" .gitattributes 2>/dev/null; then
    echo "[install-merge-drivers] OK: ${DRIVER_NAME} registered + .gitattributes wired"
else
    echo "[install-merge-drivers] WARNING: ${DRIVER_NAME} registered in .git/config but"
    echo "[install-merge-drivers] .gitattributes does not contain '.chump/state.sql merge=${DRIVER_NAME}'."
    echo "[install-merge-drivers] The driver will be invoked only after the .gitattributes change lands."
fi
