#!/usr/bin/env bash
# precommit-strict-replay.sh — INFRA-767
#
# Re-runs the critical pre-commit guards against the PR's full diff with
# their bypass env vars FORCED ON, regardless of what the contributor
# committed locally. Pre-commit guards are local + bypassable; this
# CI step is the strict branch-protection mirror.
#
# Why
#   Per CLAUDE.md and operator feedback today: "the --no-verify culture
#   means agents that don't care already bypass everything; CI catches
#   the actual ship." This step closes that gap for the high-cost
#   guards (registry, obs-budget, future ones).
#
# What it does
#   1. Saves current HEAD info.
#   2. Soft-resets HEAD to origin/main, so the PR's diff appears as
#      uncommitted-but-staged. (Working tree is unchanged.)
#   3. Stages everything (`git add -A`) so `git diff --cached` returns
#      the full PR delta — the same shape pre-commit guards parse.
#   4. Runs each registered guard with bypass env explicitly UNSET.
#   5. Aggregates results; exits non-zero if any guard tripped.
#   6. Restores HEAD via `git reset --soft <orig>` so the worktree state
#      is unchanged on completion.
#
# This step does NOT replay guards that have well-defined CI-side fixtures
# already (e.g. credential-pattern is unit-tested via
# test-credential-pattern-guard.sh on synthetic data — its pre-commit
# implementation is in the dispatcher, not its own script). Only the
# extracted guard scripts at scripts/git-hooks/pre-commit-*.sh are run.
#
# Run locally
#   scripts/ci/precommit-strict-replay.sh
#
# Bypass: there is none on the CI side. If a guard genuinely produces a
# false positive on a PR, fix the guard or expand its built-in bypass
# pattern, don't paper over here.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT" || exit 2

# In CI, BASE_REF is set by the workflow; locally fall back to origin/main.
BASE_REF="${GITHUB_BASE_REF:-main}"
BASE_FULL="origin/$BASE_REF"
if ! git rev-parse "$BASE_FULL" >/dev/null 2>&1; then
    if git rev-parse "$BASE_REF" >/dev/null 2>&1; then
        BASE_FULL="$BASE_REF"
    else
        echo "[precommit-strict] base ref $BASE_FULL not resolvable; nothing to mirror against" >&2
        exit 0
    fi
fi

# If HEAD is already at base, no PR diff to replay.
if [[ "$(git rev-parse HEAD)" == "$(git rev-parse "$BASE_FULL")" ]]; then
    echo "[precommit-strict] HEAD == $BASE_FULL; nothing to replay" >&2
    exit 0
fi

ORIG_HEAD="$(git rev-parse HEAD)"

# Restore on exit no matter how we exited.
restore_head() {
    git reset --soft "$ORIG_HEAD" >/dev/null 2>&1 || true
    git reset >/dev/null 2>&1 || true   # clear staged
}
trap restore_head EXIT

# Soft-reset HEAD to base so PR commits become uncommitted; stage them all.
git reset --soft "$BASE_FULL" >/dev/null 2>&1 || {
    echo "[precommit-strict] git reset --soft failed; aborting replay" >&2
    exit 1
}
git add -A >/dev/null 2>&1 || {
    echo "[precommit-strict] git add -A failed; aborting replay" >&2
    exit 1
}

# Run each available guard with its bypass FORCED OFF (default).
declare -a GUARDS=(
    "scripts/git-hooks/pre-commit-event-registry.sh:CHUMP_EVENT_REGISTRY_CHECK"
    "scripts/git-hooks/pre-commit-obs-budget.sh:CHUMP_OBS_BUDGET_STRICT"
    "scripts/git-hooks/pre-commit-default-flip.sh:CHUMP_DEFAULT_FLIP_CHECK"
)

OVERALL_RC=0
for entry in "${GUARDS[@]}"; do
    guard="${entry%%:*}"
    bypass_var="${entry##*:}"
    guard_path="$REPO_ROOT/$guard"
    if [[ ! -x "$guard_path" ]]; then
        # Guard not present in this PR's tree — skip silently. (Some guards
        # only exist on branches that include their introducing PR.)
        continue
    fi

    echo "[precommit-strict] replaying $guard (bypass $bypass_var FORCED off)"
    # Force guards to their active/strict state. obs-budget uses STRICT=1 to
    # enable blocking mode (INFRA-2425: BYPASS deleted, replaced by STRICT).
    if ! CHUMP_EVENT_REGISTRY_CHECK=1 \
         CHUMP_OBS_BUDGET_STRICT=1 \
         CHUMP_DEFAULT_FLIP_CHECK=1 \
         "$guard_path"; then
        echo "[precommit-strict] ✗ $guard tripped under strict replay" >&2
        OVERALL_RC=1
    fi
done

if [[ "$OVERALL_RC" -eq 0 ]]; then
    echo "[precommit-strict] ✓ all available guards passed strict replay"
fi

exit "$OVERALL_RC"
