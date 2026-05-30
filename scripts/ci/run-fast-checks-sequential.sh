#!/usr/bin/env bash
# run-fast-checks-sequential.sh — META-202 local-dev path
#
# Runs all fast-checks test-*.sh scripts SEQUENTIALLY, preserving the original
# serial behavior that existed before the CI matrix was introduced.
#
# Purpose: local development alias so you can run the full fast-checks suite
# without needing GitHub Actions matrix. Also serves as documentation of the
# complete gate list.
#
# Usage:
#   bash scripts/ci/run-fast-checks-sequential.sh
#   bash scripts/ci/run-fast-checks-sequential.sh --dry-run   # print; exit 0
#   FAST_CHECKS_STOP_ON_FAIL=1 bash scripts/ci/run-fast-checks-sequential.sh
#
# Output: PASS/FAIL per script, summary, exit 1 if any script failed.
#
# Notes:
#   - Scripts needing CHUMP_BIN auto-build debug/chump if not already present.
#   - test-pr-triage-bot.sh needs pyyaml: pip3 install pyyaml (or apt-get
#     install python3-pyyaml) before running on Linux.
#   - check-release-staleness.sh is skipped by default (needs GH_TOKEN +
#     is advisory / continue-on-error in CI). Set FAST_CHECKS_RUN_STALENESS=1
#     to include it.
#   - research-lane-a-smoke.sh lives in scripts/eval/ and needs PYTHON=python3.
#
# The authoritative list mirrors .github/workflows/ci.yml fast-checks-matrix.
# Run scripts/ci/test-fast-checks-matrix-coverage.sh to verify they are in sync.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

CI_DIR="scripts/ci"
EVAL_DIR="scripts/eval"

DRY_RUN=0
STOP_ON_FAIL="${FAST_CHECKS_STOP_ON_FAIL:-0}"
RUN_STALENESS="${FAST_CHECKS_RUN_STALENESS:-0}"

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

PASS=0
FAIL=0
SKIP=0
FAILS=()

run_script() {
    local script="$1"
    local dir="${2:-$CI_DIR}"
    local extra_env="${3:-}"
    local full_path="$REPO_ROOT/$dir/$script"

    if [[ ! -f "$full_path" ]]; then
        echo "[SKIP] $script — file not found on disk"
        SKIP=$((SKIP + 1))
        return
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[DRY-RUN] $dir/$script"
        return
    fi

    echo ""
    echo "──── $script ────"
    if env $extra_env bash "$full_path"; then
        echo "[PASS] $script"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $script"
        FAIL=$((FAIL + 1))
        FAILS+=("$script")
        if [[ "$STOP_ON_FAIL" == "1" ]]; then
            echo ""
            echo "FAST_CHECKS_STOP_ON_FAIL=1 — stopping on first failure." >&2
            exit 1
        fi
    fi
}

# ── Ensure the chump binary is built for scripts that need it ─────────────────
build_chump_if_needed() {
    local bin="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
    if [[ ! -x "$bin" ]]; then
        echo "Building chump binary (required by some tests)..."
        PATH="$HOME/.cargo/bin:$PATH" cargo build --bin chump --quiet 2>&1 | tail -3
    fi
    export CHUMP_BIN="$bin"
    export PATH="$REPO_ROOT/target/debug:$PATH"
}

# ── Group A: pure-bash scripts (no cargo build required) ─────────────────────
# These mirror the shell-only matrix entries in ci.yml fast-checks-matrix.

echo "=== fast-checks sequential: group A (shell-only) ==="

run_script test-self-hosted-runner-deps.sh
run_script test-doc-freshness.sh
run_script test-no-claude-leak.sh
run_script test-markdown-intra-doc-links.sh
run_script test-research-026-preflight.sh
run_script research-lane-a-smoke.sh "$EVAL_DIR" "PYTHON=python3"
run_script test-gap-preflight-ac-gate.sh
run_script test-chump-subcommand-help.sh
run_script test-infra-1025-atomic-claim.sh
run_script test-effective-010-completion.sh
run_script test-prereg-content-guard.sh
run_script test-cross-judge-guard.sh
run_script test-book-sync-guard.sh
run_script test-infra-124-docs-delta-trailer.sh
run_script test-merge-driver-state-sql.sh
run_script test-merge-driver-ci-yml.sh
run_script test-merge-driver-pre-commit.sh
run_script test-pr-terminal-state.sh
run_script test-subagent-budget-kill.sh
run_script test-docs-delta-commit-msg.sh
run_script test-subagent-epilogue-ref.sh
run_script test-pre-push-force-lease-guard.sh
run_script test-pre-push-rebase-allow.sh
run_script test-spike-isolation.sh
run_script test-infra-258-reaper-partial-delivery.sh
run_script test-cargo-target-reaper.sh
run_script test-gap-doctor-safe-sweep.sh
run_script test-fleet-starve-auto-action.sh
run_script test-pr-watch-auto-resolve.sh
run_script test-merged-check-guard.sh
run_script test-fleet-spec.sh
run_script test-fleet-fanout.sh
run_script test-rollup-semantic.sh
run_script test-pr-explain-block.sh
run_script test-no-verify-audit.sh
run_script test-sandbox-isolation.sh
run_script test-keystone-cascade.sh
run_script test-status-flip-proof-of-merge.sh
run_script test-pr-auto-rebase.sh
run_script test-rebase-coordination.sh
run_script test-install-pr-auto-rebase.sh
run_script test-stale-pr-rebase-bot.sh
run_script test-stale-branch-rebase.sh
run_script test-inspect-resume-scrap.sh
run_script test-claim-fuzzy-match.sh
run_script test-open-pr-dup-detection.sh
run_script test-pre-push-preflight-hook.sh
run_script test-conflict-resolver.sh
run_script test-bot-merge-conflict-wiring.sh
run_script test-pipefail-race-sweep.sh
run_script test-claude-reaper.sh
run_script test-stale-process-watchdog.sh
run_script test-default-flip-guard.sh
run_script test-git-identity-guard.sh
run_script test-hardcoded-date-guard.sh
run_script test-gap-divergence-guard.sh
run_script test-flake-autorerun.sh
run_script test-pr-blocked-watch.sh
# test-pr-triage-bot.sh needs pyyaml — skip if not installed
if python3 -c "import yaml" 2>/dev/null; then
    run_script test-pr-triage-bot.sh
else
    echo "[SKIP] test-pr-triage-bot.sh — pyyaml not installed (pip3 install pyyaml)"
    SKIP=$((SKIP + 1))
fi
run_script test-changes-job-self-hosted.sh
run_script test-migration-pipeline-gates.sh
run_script test-autoscale-decisions.sh
run_script test-model-registry.sh
run_script test-attribution-portable.sh
run_script test-infra-257-doc-only-guards.sh
run_script test-infra-109-worktree-boundary.sh
run_script test-pick-and-claim-lockdir.sh
run_script test-submodule-guard.sh
run_script test-credential-pattern-guard.sh
run_script test-docs-delta-guard.sh
run_script test-gap-status-flip.sh
run_script test-speculative-on-speculative-guard.sh
run_script test-run-fleet-cross-repo.sh
run_script test-raw-yaml-guard.sh
run_script test-meta-011-git-stomp.sh
run_script test-ambient-schema.sh
run_script test-schema-version-assert.sh
run_script test-infra-115-lease-ttl-file.sh
run_script test-obs-coverage-guard.sh
run_script test-observability-coverage.sh
run_script test-infra-254-pwa-root-redirect.sh
run_script test-auto-arm-sweeper.sh
run_script test-ci-flake-rerun.sh
run_script test-infra-250-v1-retirement.sh
run_script test-install-ambient-hooks.sh
run_script test-mcp-coord-smoke.sh
run_script test-env-var-coverage.sh
run_script test-cli-version-debug.sh
run_script test-pre-push-test-gate.sh
run_script test-pr-watch-shepherd-smoke.sh
run_script test-md-links-loop.sh
run_script test-gap-preflight-ac-gate.sh

# Advisory/staleness check (skip by default; needs GH_TOKEN)
if [[ "$RUN_STALENESS" == "1" ]]; then
    run_script check-release-staleness.sh
else
    echo "[SKIP] check-release-staleness.sh (set FAST_CHECKS_RUN_STALENESS=1 to include)"
    SKIP=$((SKIP + 1))
fi

# ── Group B: scripts needing the chump binary ─────────────────────────────────
echo ""
echo "=== fast-checks sequential: group B (chump-bin) ==="
[[ "$DRY_RUN" == "1" ]] || build_chump_if_needed

run_script test-fleet-brief.sh
run_script test-orchestrate-session-summary.sh
run_script test-gap-reserve-concurrency.sh
run_script test-gap-reserve-padding.sh
run_script test-gap-id-cross-session.sh
run_script test-gap-id-lease-uniqueness.sh
run_script test-bot-merge-auto-close.sh
run_script test-infra-119-bot-merge-hang.sh
run_script coord-surfaces-smoke.sh
run_script test-cli-help.sh
run_script test-cli-fleet-coord.sh
run_script test-cli-integration.sh
run_script test-gate-promotion-no-regression.sh
run_script test-preflight-ci-parity.sh

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "fast-checks sequential summary"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "  SKIP: $SKIP"
if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "Failed scripts:"
    for f in "${FAILS[@]}"; do
        echo "  - $f"
    done
    echo "========================================"
    exit 1
fi
echo "========================================"
exit 0
